defmodule Tay.Engine.CompactionRuntimeTest do
  use ExUnit.Case, async: false

  alias Tay.Test.{
    EngineHelpers,
    EngineWorker,
    ExecutionHelpers,
    ExecutionClock,
    NativeHelpers,
    RecoveryHelpers
  }

  alias Tay.Engine.CompactionPolicy
  @name __MODULE__
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install(100)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, options \\ []) do
    {:ok, root} = EngineHelpers.restart(path, @name, [test_clock: ExecutionClock] ++ options)
    Process.unlink(root)
    on_exit(fn -> EngineHelpers.stop(root) end)
    root
  end

  defp policy(root) do
    Enum.find_value(Supervisor.which_children(root), fn
      {CompactionPolicy, pid, _, _} -> pid
      _ -> nil
    end)
  end

  defp evaluate(pid) do
    {_, token} = :sys.get_state(pid).timer
    send(pid, {:evaluate, token})
  end

  defp insert(args \\ %{}, options \\ []) do
    {:ok, intent} = EngineWorker.new(args, options)
    result = Tay.insert(intent, name: @name)

    assert {:ok, job} = result,
           "insert result #{inspect(result)}; status #{inspect(Tay.status(name: @name))}; reconcile #{inspect(Tay.get_job(intent.id, name: @name))}"

    job
  end

  # Read-only measurements of disposable qualification stores, never production
  # inventory or publication. Called at stable owner-held test barriers.
  defp logical_file_bytes(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} ->
        size

      {:ok, %{type: :directory}} ->
        {:ok, names} = File.ls(path)
        Enum.sum(Enum.map(names, &logical_file_bytes(Path.join(path, &1))))

      _ ->
        0
    end
  end

  defp measurements(acc \\ []) do
    receive do
      {:resource_boundary, tag, disk, memory, binaries} ->
        measurements([{tag, disk, memory, binaries} | acc])
    after
      0 -> acc
    end
  end

  test "cooldown starts no earlier than post-publication activation", %{path: path} do
    hook = fn
      {:compaction, :current_published}, _ -> ExecutionHelpers.set_clock(100_100)
      _, _ -> :ok
    end

    start(path, writer_hook: hook)
    assert {:ok, stats} = Tay.compact(name: @name, timeout: 60_000)
    assert stats.captured_at == 100
    engine = :sys.get_state(@name).engine
    assert :sys.get_state(engine).last_compaction_at == 100_100
    assert :ok = Tay.restart(name: @name, timeout: 60_000)
    engine = :sys.get_state(@name).engine
    assert :sys.get_state(engine).last_compaction_at == 100_100
  end

  # Disposable retained-history fixture: stream frames and CRCs without keeping
  # an 80 MiB segment in the test process. Actual compaction below is automatic,
  # through the production evaluator/permit/Writer/publication/recovery path.
  defp retained_history(path) do
    alias Tay.Test.{EventHelpers, SegmentHelpers}
    alias Tay.Storage.CRC32C
    header = SegmentHelpers.header()
    {:ok, file} = File.open(RecoveryHelpers.canonical(path, 1), [:write, :binary])
    :ok = IO.binwrite(file, header)
    initial = {file, 1, header, CRC32C.update(CRC32C.initial(), header), 44, 0, 1}
    payload = :binary.copy("x", 8_000)

    final =
      Enum.reduce(1..10_000, initial, fn index, state ->
        definition =
          EventHelpers.definition(%{
            "args" => %{"history" => payload, "index" => index},
            "scheduled_at" => if(index > 9_500, do: nil, else: 200_000_000)
          })

        state =
          history_frame(
            path,
            state,
            EventHelpers.inserted(definition, 100, EventHelpers.id(index))
          )

        if index <= 9_000 do
          {_, _, _, _, _, _, next} = state
          at = if index <= 8_000, do: 100, else: 89_000_100

          history_frame(
            path,
            state,
            EventHelpers.event(
              5,
              at,
              next - 1,
              %{"execution_token" => nil},
              EventHelpers.id(index)
            )
          )
        else
          state
        end
      end)

    {file, _, _, _, _, _, _} = final
    :ok = File.close(file)
  end

  defp history_frame(path, {file, id, header, crc, bytes, count, next}, event) do
    alias Tay.Test.SegmentHelpers
    alias Tay.Storage.CRC32C
    {:ok, {type, schema, payload}} = Tay.Event.encode(event)

    {:ok, frame} =
      Tay.Storage.Record.encode(%Tay.Storage.Record{
        record_type: type,
        payload_schema_version: schema,
        payload: payload,
        sequence: next
      })

    {file, id, header, crc, bytes, count} =
      if bytes + byte_size(frame) + 64 > 67_108_864 do
        footer =
          SegmentHelpers.footer(header, [],
            count: count,
            last_sequence: next - 1,
            segment_crc: CRC32C.finalize(crc)
          )

        :ok = IO.binwrite(file, footer)
        :ok = File.close(file)
        header = SegmentHelpers.header(id: id + 1, first_sequence: next)
        {:ok, file} = File.open(RecoveryHelpers.canonical(path, id + 1), [:write, :binary])
        :ok = IO.binwrite(file, header)
        {file, id + 1, header, CRC32C.update(CRC32C.initial(), header), 44, 0}
      else
        {file, id, header, crc, bytes, count}
      end

    :ok = IO.binwrite(file, frame)
    {file, id, header, CRC32C.update(crc, frame), bytes + byte_size(frame), count + 1, next + 1}
  end

  @tag timeout: 900_000
  @tag :phase_c_10000
  @tag skip: System.get_env("TAY_PHASE_C_10000") != "1"
  test "10,000 retained jobs use default automatic retention and recover exact survivors", %{
    path: path
  } do
    retained_history(path)
    owner = self()
    table = :ets.new(:compaction_metrics, [:public, :set])
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    :ok =
      :logger.add_handler(:phase_c_metrics, Tay.Test.CompactionMetrics, %{
        level: :debug,
        table: table
      })

    on_exit(fn ->
      :logger.remove_handler(:phase_c_metrics)
      Logger.configure(level: previous_level)
    end)

    hook = fn
      {:compaction, tag}, _ ->
        # Memory samples per snapshot; expensive logical inventory samples only
        # at five fixed boundaries, not on every one of 2,000 base writes.
        {:memory, memory} = Process.info(self(), :memory)
        :ets.update_counter(table, :samples, {2, 1}, {:samples, 0})

        :ets.insert(
          table,
          {{:memory, :ets.lookup_element(table, :samples, 2)}, memory, :erlang.memory(:total)}
        )

        if tag != :base_write or not Process.get(:sampled_base) do
          Process.put(:sampled_base, true)
          send(owner, {:resource_boundary, tag, logical_file_bytes(path), memory, 0})
        end

        :ok

      _, _ ->
        :ok
    end

    ExecutionHelpers.set_clock(90_000_100)
    root = start(path, writer_hook: hook, caller_timeout: 60_000, workers: %{})
    assert Tay.status(name: @name).jobs == 10_000
    p = policy(root)

    headroom_checks =
      if System.get_env("TAY_PHASE_C_HEADROOM") == "1" do
        # An external disposable reservation, never source/candidate deletion to
        # obtain headroom. Run only on the dedicated validated Btrfs volume.
        reserve = path <> "-headroom-reservation"
        {output, 0} = System.cmd("df", ["-B1", "--output=avail", path])
        free = output |> String.split() |> List.last() |> String.to_integer()
        assert free > 100_000_000
        {_, 0} = System.cmd("fallocate", ["-l", Integer.to_string(free - 32_000_000), reserve])
        on_exit(fn -> File.rm(reserve) end)
        evaluate(p)

        assert EngineHelpers.eventually(
                 fn -> :sys.get_state(p).last_result == {:deferred, :insufficient_headroom} end,
                 60_000
               )

        refute File.exists?(Path.join(path, "CURRENT"))
        assert Tay.status(name: @name).jobs == 10_000
        assert File.stat!(RecoveryHelpers.canonical(path, 1)).size > 60_000_000
        :ok = File.rm(reserve)
        # Btrfs unlink may defer freeing extents until transaction commit. Wait
        # for the external reservation's actual release before expecting retry
        # success; never alter source data to manufacture candidate headroom.
        {_, 0} = System.cmd("sync", ["-f", Path.dirname(path)])

        assert EngineHelpers.eventually(fn ->
                 {output, 0} = System.cmd("df", ["-B1", "--output=avail", path])

                 output
                 |> String.split()
                 |> List.last()
                 |> String.to_integer()
                 |> Kernel.>(100_000_000)
               end)

        1
      else
        0
      end

    state = :sys.get_state(:sys.get_state(@name).engine)

    {:ok, admitted_estimate} =
      Tay.Engine.CompactionEstimate.summarize(
        state.compaction_estimate,
        state.history_bytes - state.segment.bytes,
        state.segment_count - 1,
        {:hours, 24},
        90_000_100
      )

    started = System.monotonic_time(:millisecond)
    evaluate(p)

    assert EngineHelpers.eventually(
             fn -> match?({:ok, _}, :sys.get_state(p).last_result) end,
             60_000
           )

    elapsed = System.monotonic_time(:millisecond) - started
    assert {:ok, stats} = :sys.get_state(p).last_result
    assert stats.expired_jobs == 8_000
    assert stats.retained_terminal_jobs == 1_000
    assert stats.reclaimed_bytes == stats.source_bytes
    assert stats.candidate_bytes <= admitted_estimate.candidate_upper_bytes
    assert admitted_estimate.reclaimable_bytes <= stats.source_bytes - stats.candidate_bytes
    assert Tay.status(name: @name).jobs == 2_000

    for index <- 1..10_000 do
      id = Tay.JobID.encode(Tay.Test.EventHelpers.id(index))

      case index do
        n when n <= 8_000 -> assert {:error, :not_found} = Tay.get_job(id, name: @name)
        n when n <= 9_000 -> assert {:ok, %{state: :cancelled}} = Tay.get_job(id, name: @name)
        n when n <= 9_500 -> assert {:ok, %{state: :scheduled}} = Tay.get_job(id, name: @name)
        _ -> assert {:ok, %{state: :available}} = Tay.get_job(id, name: @name)
      end
    end

    current = File.read!(Path.join(path, "CURRENT"))
    assert :ok = Tay.restart(name: @name, timeout: 900_000)
    assert Tay.status(name: @name).jobs == 2_000
    ExecutionHelpers.set_clock(90_000_100 + 3_600_000)

    for _ <- 1..100 do
      evaluate(p)
      assert EngineHelpers.eventually(fn -> :sys.get_state(p).pending == nil end)
    end

    assert File.read!(Path.join(path, "CURRENT")) == current
    # Independently recover the selected authority on startup and check every
    # survivor again: expired IDs cannot resurrect, protected jobs cannot vanish.
    EngineHelpers.stop(root)
    start(path, workers: %{})

    for index <- 1..10_000 do
      id = Tay.JobID.encode(Tay.Test.EventHelpers.id(index))

      if index <= 8_000,
        do: assert({:error, :not_found} = Tay.get_job(id, name: @name)),
        else: assert({:ok, _} = Tay.get_job(id, name: @name))
    end

    events = :ets.tab2list(table)
    durations = for {{:evaluation, _}, duration} <- events, do: duration
    writer = for {{:memory, _}, memory, _} <- events, do: memory
    vm = for {{:memory, _}, _, memory} <- events, do: memory

    count = fn event ->
      case :ets.lookup(table, {:event, event}) do
        [{_, n}] -> n
        [] -> 0
      end
    end

    assert count.(:automatic_compaction_completed) == 1
    assert count.(:evaluation_skipped) == 100
    assert count.(:evaluation_performed) == 101 + headroom_checks
    measured = measurements()

    IO.puts(
      "PHASE_C_AUTOMATIC_10000 " <>
        inspect(
          Map.merge(stats, %{
            jobs_before: 10_000,
            expired_cancelled: 8_000,
            recent_cancelled: 1_000,
            scheduled: 500,
            available: 500,
            retention_hours: 24,
            automatic_total_ms: elapsed,
            evaluations: count.(:evaluation_performed),
            no_op_evaluations: count.(:evaluation_skipped),
            automatic_compactions: count.(:automatic_compaction_completed),
            evaluation_us_sum: Enum.sum(durations),
            evaluation_us_max: Enum.max(durations),
            candidate_source_ratio: stats.candidate_bytes / stats.source_bytes,
            sampled_peak_logical_disk_bytes: Enum.max(Enum.map(measured, &elem(&1, 1))),
            sampled_writer_process_peak_bytes: Enum.max(writer),
            sampled_vm_total_peak_bytes: Enum.max(vm),
            recovery_jobs: 2_000,
            current_unchanged_after_100_noops: true
          })
        )
    )
  end

  test "manual finite cutoff, default policy, restart and expired public mutators", %{path: path} do
    root = start(path)

    jobs =
      for at <- [99, 100, 101] do
        ExecutionHelpers.set_clock(at)
        job = insert(%{"at" => at})
        assert {:ok, cancelled} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
        cancelled
      end

    live = insert(%{"live" => true})
    ExecutionHelpers.set_clock(3_600_100)

    assert {:ok, stats} =
             Tay.compact(name: @name, timeout: 60_000, terminal_retention: {:hours, 1})

    assert stats.expired_jobs == 2
    assert stats.retained_terminal_jobs == 1
    assert stats.captured_at == 3_600_100
    assert stats.recovered.manifest.terminal_retention == {:hours, 1}
    assert stats.recovered.manifest.captured_at == stats.captured_at
    assert stats.admitted_candidate_bytes >= stats.candidate_bytes

    for job <- Enum.take(jobs, 2) do
      assert {:error, :not_found} = Tay.get_job(job.id, name: @name)

      assert {:error, :not_found} =
               Tay.retry(job.id, name: @name, expected_revision: job.revision)

      assert {:error, :not_found} =
               Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    end

    assert {:ok, %{state: :cancelled}} = Tay.get_job(List.last(jobs).id, name: @name)
    assert {:ok, %{state: :available}} = Tay.get_job(live.id, name: @name)
    EngineHelpers.stop(root)
    start(path)
    assert {:error, :not_found} = Tay.get_job(hd(jobs).id, name: @name)
    assert {:ok, %{state: :available}} = Tay.get_job(live.id, name: @name)
    assert {:ok, stats} = Tay.compact(name: @name, timeout: 60_000)
    assert stats.recovered.manifest.terminal_retention == {:hours, 24}

    for invalid <- [false, nil, :forever, {:hours, 0}, {:hours, 1.0}] do
      assert {:error, %{kind: :invalid}} = Tay.compact(name: @name, terminal_retention: invalid)
    end
  end

  test "terminal pressure retains only the newest configured history across restart", %{
    path: path
  } do
    root = start(path, compaction: [enabled: false, max_terminal_jobs: 2])

    jobs =
      for at <- 1..4 do
        ExecutionHelpers.set_clock(at)
        job = insert(%{"at" => at})
        assert {:ok, cancelled} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
        cancelled
      end

    assert {:ok, stats} =
             Tay.compact(name: @name, timeout: 60_000, terminal_retention: {:hours, 24})

    assert stats.pressure_expired_jobs == 3
    assert stats.retained_terminal_jobs == 1

    for job <- Enum.take(jobs, 3),
        do: assert({:error, :not_found} = Tay.get_job(job.id, name: @name))

    for job <- Enum.drop(jobs, 3),
        do: assert({:ok, %{state: :cancelled}} = Tay.get_job(job.id, name: @name))

    EngineHelpers.stop(root)
    start(path, compaction: [enabled: false, max_terminal_jobs: 2])
    assert {:ok, stats} = Tay.stats(name: @name)
    assert stats.cancelled == 1
  end

  test "automatic policy compacts fresh terminal pressure without waiting for time retention", %{
    path: path
  } do
    start(path,
      compaction: [max_terminal_jobs: 2, check_interval: 60_000, min_interval: 60_000]
    )

    for at <- 1..3 do
      ExecutionHelpers.set_clock(at)
      job = insert(%{"at" => at})
      assert {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    end

    assert EngineHelpers.eventually(fn ->
             Tay.status(name: @name).state == :ready and
               match?({:ok, %{cancelled: 1}}, Tay.stats(name: @name))
           end)

    current = File.read!(Path.join(path, "CURRENT"))
    job = insert(%{"at" => 4})
    assert {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    assert {:ok, %{cancelled: 2}} = Tay.stats(name: @name)
    Process.sleep(100)
    assert :sys.get_state(@name).operation == nil
    assert File.read!(Path.join(path, "CURRENT")) == current
  end

  test "bounded expiry lost-CURRENT reply uses exact retained view", %{path: path} do
    start(path, storage_timeout: 500)
    old = insert()
    assert {:ok, _} = Tay.cancel(old.id, name: @name, expected_revision: old.revision)
    ExecutionHelpers.set_clock(3_600_100)
    writer = :sys.get_state(@name).writer
    :ok = Tay.Storage.Writer.inject_fault(writer, :v2_publish_current, 1, :drop_reply)

    assert {:ok, stats} =
             Tay.compact(name: @name, timeout: 60_000, terminal_retention: {:hours, 1})

    assert stats.publication_reconciled
    assert stats.expired_jobs == 1
    assert {:error, :not_found} = Tay.get_job(old.id, name: @name)
    assert Tay.status(name: @name).state == :ready
  end

  test "shutdown while CURRENT reply is lost settles/reconciles instead of cancelling authority",
       %{path: path} do
    owner = self()

    hook = fn
      {:compaction, :before_current}, _ ->
        send(owner, {:current_barrier, self()})
        receive do: (:continue -> :ok)

      _, _ ->
        :ok
    end

    root = start(path, storage_timeout: 1000, writer_hook: hook)
    original = insert()
    writer = :sys.get_state(@name).writer
    :ok = Tay.Storage.Writer.inject_fault(writer, :v2_publish_current, 1, :drop_reply)
    compact = Task.async(fn -> Tay.compact(name: @name, timeout: 60_000) end)
    assert_receive {:current_barrier, ^writer}, 5000
    send(writer, :continue)

    assert EngineHelpers.eventually(fn ->
             {:dictionary, dictionary} = Process.info(writer, :dictionary)

             match?(
               {_, {_, :publishing}},
               List.keyfind(dictionary, {Tay.Storage.V2.CompactionControl, :owner_control}, 0)
             )
           end)

    stop = Task.async(fn -> Supervisor.stop(root) end)
    assert :ok = Task.await(stop, 60_000)
    _ = Task.await(compact, 60_000)
    assert File.exists?(Path.join(path, "CURRENT"))
    start(path)
    assert {:ok, recovered} = Tay.get_job(original.id, name: @name)
    assert recovered.definition == original.definition
  end

  test "one evaluator/timer; stale messages, disabled opt-out, idle no-churn and restart reset",
       %{path: path} do
    root = start(path)
    p = policy(root)
    assert is_pid(p)
    initial = :sys.get_state(p)
    send(p, {:evaluate, make_ref()})
    send(p, {:policy_estimate, make_ref(), {:error, :busy}})
    send(p, {{:compaction_policy, make_ref()}, {:ok, %{secret_payload: "stale"}}})
    assert :sys.get_state(p).timer == initial.timer
    assert :sys.get_state(p).last_result == nil

    for _ <- 1..100 do
      {old_timer, _} = :sys.get_state(p).timer
      evaluate(p)
      assert EngineHelpers.eventually(fn -> :sys.get_state(p).pending == nil end)
      assert Process.read_timer(old_timer) == false
    end

    refute File.exists?(Path.join(path, "CURRENT"))
    assert {:message_queue_len, 0} = Process.info(p, :message_queue_len)
    assert :ok = Tay.restart(name: @name, timeout: 60_000)
    assert policy(root) == p
    assert :sys.get_state(p).pending == nil
    EngineHelpers.stop(root)
    disabled = start(path, compaction: false)
    assert policy(disabled) == nil
    assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000, terminal_retention: :infinity)
  end

  test "manual slot contention and public draining defer automatic evaluation", %{path: path} do
    owner = self()

    hook = fn
      {:compaction, :before_candidate}, _ ->
        send(owner, {:candidate_barrier, self()})
        receive do: (:continue -> :ok)

      _, _ ->
        :ok
    end

    root = start(path, writer_hook: hook)
    p = policy(root)
    manual = Task.async(fn -> Tay.compact(name: @name, timeout: 60_000) end)
    assert_receive {:candidate_barrier, writer}, 5000
    evaluate(p)
    assert EngineHelpers.eventually(fn -> :sys.get_state(p).pending == nil end)
    assert {:error, %{reason: :operation_slot}} = Tay.compact(name: @name)
    send(writer, :continue)
    assert {:ok, _} = Task.await(manual, 60_000)
    assert :ok = Tay.drain(name: @name)
    evaluate(p)
    assert EngineHelpers.eventually(fn -> :sys.get_state(p).pending == nil end)
    assert :sys.get_state(@name).operation == nil
  end

  test "generation and admission-close source races cannot publish stale estimates", %{path: path} do
    owner = self()

    hook = fn
      {:operations, :draining} ->
        send(owner, {:drain_barrier, self()})
        receive do: (:continue -> :ok)

      _ ->
        :ok
    end

    root = start(path, test_hook: hook)
    p = policy(root)
    generation = :sys.get_state(@name).meta.generation
    GenServer.cast(@name, {:automatic_compaction, p, make_ref(), make_ref(), {nil, 1}})
    assert :sys.get_state(@name).operation == nil
    insert()
    GenServer.cast(@name, {:automatic_compaction, p, make_ref(), generation, {nil, 1}})
    assert EngineHelpers.eventually(fn -> :sys.get_state(@name).operation == nil end)
    refute_receive {:drain_barrier, _}
    assert :sys.get_state(@name).meta.generation == generation
    refute File.exists?(Path.join(path, "CURRENT"))
    assert Tay.status(name: @name).state == :ready
  end

  test "stopping and recovering owners defer without entering Writer compaction", %{path: path} do
    owner = self()
    flag = :atomics.new(1, [])

    writer_hook = fn
      :recovery_replayed, _ ->
        if :atomics.get(flag, 1) == 1 do
          send(owner, {:recovery_barrier, self()})
          receive do: (:continue -> :ok)
        end

        :ok

      _, _ ->
        :ok
    end

    hook = fn
      {:operations, :pre_result} ->
        if :atomics.get(flag, 1) == 2 do
          send(owner, {:stop_barrier, self()})
          receive do: (:continue -> :ok)
        end

      _ ->
        :ok
    end

    root = start(path, writer_hook: writer_hook, test_hook: hook)
    p = policy(root)
    :atomics.put(flag, 1, 1)
    restart = Task.async(fn -> Tay.restart(name: @name, timeout: 60_000) end)
    assert_receive {:recovery_barrier, writer}, 5_000
    evaluate(p)

    assert EngineHelpers.eventually(fn ->
             :sys.get_state(p).last_result == {:deferred, :recovering}
           end)

    refute File.exists?(Path.join(path, "CURRENT"))
    :atomics.put(flag, 1, 0)
    send(writer, :continue)
    assert :ok = Task.await(restart, 60_000)
    :atomics.put(flag, 1, 2)
    stop = Task.async(fn -> Tay.stop(name: @name, timeout: 60_000) end)
    assert_receive {:stop_barrier, driver}, 5_000
    evaluate(p)

    assert EngineHelpers.eventually(fn ->
             :sys.get_state(p).last_result == {:deferred, :stopping}
           end)

    send(driver, :continue)
    assert :ok = Task.await(stop, 60_000)
    evaluate(p)

    assert EngineHelpers.eventually(fn ->
             :sys.get_state(p).last_result == {:deferred, :stopped}
           end)

    refute File.exists?(Path.join(path, "CURRENT"))
  end

  test "public execution drain defers automatic work without forcing callback death", %{
    path: path
  } do
    root =
      start(path,
        test_execution: true,
        workers: %{"execution.test.v1" => Tay.Test.ExecutionWorker}
      )

    {job, token} = ExecutionHelpers.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = ExecutionHelpers.await_entry(token)
    drain = Task.async(fn -> Tay.drain(name: @name, timeout: 60_000) end)
    assert EngineHelpers.eventually(fn -> Tay.status(name: @name).state == :draining end)
    p = policy(root)
    evaluate(p)

    assert EngineHelpers.eventually(fn ->
             :sys.get_state(p).last_result == {:deferred, :draining}
           end)

    assert Process.alive?(task)
    refute File.exists?(Path.join(path, "CURRENT"))
    send(task, {:return, :ok})
    assert :ok = Task.await(drain, 60_000)
  end

  test "ownership loss cannot authorize compaction; fresh evaluator recovers authoritative source",
       %{path: path} do
    root = start(path)
    p = policy(root)
    original = insert()
    Process.exit(:sys.get_state(@name).writer, :kill)
    assert EngineHelpers.eventually(fn -> Tay.status(name: @name).state == :failed end)
    evaluate(p)

    assert EngineHelpers.eventually(fn ->
             :sys.get_state(p).last_result == {:deferred, :unhealthy}
           end)

    refute File.exists?(Path.join(path, "CURRENT"))
    EngineHelpers.stop(root)
    fresh = start(path)
    refute policy(fresh) == p
    assert :sys.get_state(policy(fresh)).pending == nil
    assert {:ok, _} = Tay.get_job(original.id, name: @name)
  end

  test "shutdown invalidates an asynchronous estimate pending at the old Engine", %{path: path} do
    root = start(path)
    p = policy(root)
    engine = :sys.get_state(@name).engine
    :ok = :sys.suspend(engine)
    evaluate(p)
    assert EngineHelpers.eventually(fn -> match?({:estimate, _}, :sys.get_state(p).pending) end)
    stop = Task.async(fn -> Supervisor.stop(root) end)
    assert EngineHelpers.eventually(fn -> not Process.alive?(p) end)
    assert :ok = Task.await(stop, 60_000)
    refute Process.alive?(engine)
    refute File.exists?(Path.join(path, "CURRENT"))
    fresh = start(path)
    assert :sys.get_state(policy(fresh)).pending == nil
  end

  test "automatic maintenance defers during active execution and shutdown preserves CURRENT", %{
    path: path
  } do
    root =
      start(path,
        compaction: [min_reclaimable_bytes: 1],
        test_execution: true,
        workers: %{"worker.v1" => EngineWorker, "execution.test.v1" => Tay.Test.ExecutionWorker}
      )

    old =
      for _ <- 1..6 do
        job = insert(%{"history" => :binary.copy("x", 250_000)}, scheduled_at: 5_000_000)
        assert {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
        job
      end

    assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000, terminal_retention: :infinity)
    current = File.read!(Path.join(path, "CURRENT"))
    {completed, completed_token} = ExecutionHelpers.job()
    assert {:ok, _} = Tay.insert(completed, name: @name)
    {completed_task, _} = ExecutionHelpers.await_entry(completed_token)
    send(completed_task, {:return, :ok})

    assert EngineHelpers.eventually(fn ->
             match?({:ok, %{state: :completed}}, Tay.get_job(completed.id, name: @name))
           end)

    assert {:ok, %{revision: {:tay_revision_v2, _, _, _, _, 3}}} =
             Tay.get_job(completed.id, name: @name)

    {active, token} = ExecutionHelpers.job()
    assert {:ok, _} = Tay.insert(active, name: @name)
    {task, _} = ExecutionHelpers.await_entry(token)
    ExecutionHelpers.set_clock(90_000_100)
    p = policy(root)
    evaluate(p)

    assert EngineHelpers.eventually(fn ->
             :sys.get_state(p).last_result == {:deferred, :active_jobs_present}
           end)

    assert :sys.get_state(@name).operation == nil
    assert Process.alive?(task)
    stop = Task.async(fn -> Supervisor.stop(root) end)
    assert :ok = Task.await(stop, 60_000)
    refute Process.alive?(p)
    refute Process.alive?(task)
    assert File.read!(Path.join(path, "CURRENT")) == current
    start(path)
    for job <- [active, completed | old], do: assert({:ok, _} = Tay.get_job(job.id, name: @name))
  end

  for {target, count} <- [{16_777_352, 160}, {67_108_864, 340}] do
    @target target
    @count count
    @tag timeout: 900_000
    @tag :phase_c_workload
    @tag skip: System.get_env("TAY_PHASE_C_WORKLOAD") != "1"
    test "default gates reclaim expired history at rotation #{target} without churn", %{
      path: path
    } do
      owner = self()

      hook = fn
        {:compaction, tag}, _ ->
          {:memory, memory} = Process.info(self(), :memory)
          {:binary, binaries} = Process.info(self(), :binary)
          bytes = Enum.sum(Enum.map(binaries, fn {_, size, _} -> size end))
          send(owner, {:resource_boundary, tag, logical_file_bytes(path), memory, bytes})
          :ok

        _, _ ->
          :ok
      end

      root =
        start(path,
          rotation_target_bytes: @target,
          caller_timeout: 60_000,
          writer_hook: hook,
          test_execution: true,
          workers: %{"worker.v1" => EngineWorker, "execution.test.v1" => Tay.Test.ExecutionWorker}
        )

      payload = :binary.copy("x", 250_000)

      jobs =
        for index <- 1..@count do
          job = insert(%{"index" => index, "retained_bytes" => payload}, scheduled_at: 5_000_000)
          assert {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
          job
        end

      p = policy(root)
      {active, active_token} = ExecutionHelpers.job()
      assert {:ok, _} = Tay.insert(active, name: @name)
      {task, _} = ExecutionHelpers.await_entry(active_token)
      engine = :sys.get_state(@name).engine
      state = :sys.get_state(engine)
      ExecutionHelpers.set_clock(90_000_100)

      {:ok, estimate} =
        Tay.Engine.CompactionEstimate.summarize(
          state.compaction_estimate,
          state.history_bytes - state.segment.bytes,
          state.segment_count - 1,
          {:hours, 24},
          90_000_100
        )

      assert {:error, :active_jobs_present} =
               CompactionPolicy.eligible(
                 Map.put(estimate, :last_compaction_at, nil),
                 :sys.get_state(p).config,
                 90_000_100
               )

      started = System.monotonic_time(:millisecond)
      evaluate(p)

      assert EngineHelpers.eventually(fn ->
               :sys.get_state(p).last_result == {:deferred, :active_jobs_present}
             end)

      assert :sys.get_state(@name).operation == nil
      assert Process.alive?(task)
      refute File.exists?(Path.join(path, "CURRENT"))
      assert EngineHelpers.eventually(fn -> :sys.get_state(engine).mode == :ready end)
      send(task, {:return, :ok})

      assert EngineHelpers.eventually(fn ->
               match?({:ok, %{state: :completed}}, Tay.get_job(active.id, name: @name))
             end)

      evaluate(p)

      assert EngineHelpers.eventually(
               fn -> match?({:ok, _}, :sys.get_state(p).last_result) end,
               12_000
             )

      total_ms = System.monotonic_time(:millisecond) - started
      assert {:ok, stats} = :sys.get_state(p).last_result
      assert stats.expired_jobs == @count
      assert stats.retained_terminal_jobs == 1
      assert {:ok, %{state: :completed}} = Tay.get_job(active.id, name: @name)
      assert stats.reclaimed_bytes == stats.source_bytes
      assert stats.source_bytes > 32_000_000
      assert stats.candidate_bytes <= estimate.candidate_upper_bytes
      assert estimate.reclaimable_bytes <= stats.source_bytes - stats.candidate_bytes
      for job <- jobs, do: assert({:error, :not_found} = Tay.get_job(job.id, name: @name))
      {:ok, current} = File.read(Path.join(path, "CURRENT"))
      ExecutionHelpers.set_clock(90_000_100 + 3_600_000)

      for _ <- 1..100 do
        evaluate(p)
        assert EngineHelpers.eventually(fn -> :sys.get_state(p).pending == nil end)
      end

      assert File.read!(Path.join(path, "CURRENT")) == current

      measured = measurements()
      peak_disk = Enum.max(Enum.map(measured, &elem(&1, 1)))
      peak_memory = Enum.max(Enum.map(measured, &elem(&1, 2)))
      peak_binaries = Enum.max(Enum.map(measured, &elem(&1, 3)))

      IO.puts(
        "PHASE_C_DEFAULT_WORKLOAD " <>
          inspect(
            Map.merge(stats, %{
              automatic_total_ms: total_ms,
              candidate_source_amplification: stats.candidate_bytes / stats.source_bytes,
              logical_source_plus_candidate_amplification:
                1 + stats.candidate_bytes / stats.source_bytes,
              sampled_peak_logical_disk_bytes: peak_disk,
              sampled_peak_logical_disk_amplification: peak_disk / stats.source_bytes,
              sampled_writer_process_bytes: peak_memory,
              sampled_writer_referenced_binary_bytes: peak_binaries,
              conservative_estimate: estimate.reclaimable_bytes,
              retained_terminal_jobs_before: @count,
              rotation_target_bytes: @target
            })
          )
      )
    end
  end

  for site <- [
        :before_candidate,
        :base_write,
        :epoch_published,
        :before_current,
        :current_published
      ] do
    @site site
    test "supervisor shutdown settles owner at #{site}", %{path: path} do
      owner = self()

      hook = fn
        {:compaction, @site}, _ ->
          unless Process.get(:compaction_barrier_reached) do
            Process.put(:compaction_barrier_reached, true)
            send(owner, {:compaction_barrier, self()})
            receive do: (:continue -> :ok)
          end

          :ok

        _, _ ->
          :ok
      end

      root = start(path, writer_hook: hook)
      original = insert(%{"shutdown_site" => Atom.to_string(@site)})
      manual = Task.async(fn -> Tay.compact(name: @name, timeout: 60_000) end)
      assert_receive {:compaction_barrier, writer}, 5000
      stop = Task.async(fn -> Supervisor.stop(root) end)

      assert EngineHelpers.eventually(fn ->
               s = :sys.get_state(@name)
               s.shutdown_waiter != nil and :atomics.get(s.operation.cancel_flag, 1) == 1
             end)

      assert Task.yield(stop, 10) == nil
      send(writer, :continue)
      assert :ok = Task.await(stop, 60_000)
      _ = Task.await(manual, 60_000)

      if @site == :current_published,
        do: assert(File.exists?(Path.join(path, "CURRENT"))),
        else: refute(File.exists?(Path.join(path, "CURRENT")))

      start(path)
      assert {:ok, recovered} = Tay.get_job(original.id, name: @name)
      assert recovered.state == original.state
      assert recovered.definition == original.definition
    end

    test "deadline at #{site} preserves old authority or settles published CURRENT", %{path: path} do
      owner = self()

      hook = fn
        {:compaction, @site}, _ ->
          unless Process.get(:deadline_barrier_reached) do
            Process.put(:deadline_barrier_reached, true)
            send(owner, {:deadline_barrier, self()})
            receive do: (:continue -> :ok)
          end

          :ok

        _, _ ->
          :ok
      end

      start(path, writer_hook: hook)
      original = insert()
      compact = Task.async(fn -> Tay.compact(name: @name, timeout: 500) end)
      assert_receive {:deadline_barrier, writer}, 5000
      assert {:error, %{kind: kind}} = Task.await(compact, 5000)
      assert kind in [:timeout, :unknown_outcome]
      send(writer, :continue)
      assert EngineHelpers.eventually(fn -> :sys.get_state(@name).operation == nil end, 1000)

      if @site == :current_published,
        do: assert(File.exists?(Path.join(path, "CURRENT"))),
        else: refute(File.exists?(Path.join(path, "CURRENT")))

      assert Tay.status(name: @name).state == :ready
      assert {:ok, recovered} = Tay.get_job(original.id, name: @name)
      assert recovered.definition == original.definition
    end
  end
end
