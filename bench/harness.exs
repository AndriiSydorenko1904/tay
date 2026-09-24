defmodule Tay.Bench.Stats do
  @moduledoc false
  def distribution([]),
    do: %{count: 0, min: nil, mean: nil, p50: nil, p95: nil, p99: nil, max: nil}

  def distribution(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      count: count,
      min: hd(sorted),
      mean: Enum.sum(sorted) / count,
      p50: Enum.at(sorted, max(ceil(count * 0.50) - 1, 0)),
      p95: Enum.at(sorted, max(ceil(count * 0.95) - 1, 0)),
      p99: Enum.at(sorted, max(ceil(count * 0.99) - 1, 0)),
      max: List.last(sorted)
    }
  end

  def json(value), do: :json.encode(normalize(value)) |> IO.iodata_to_binary()
  defp normalize(nil), do: :null
  defp normalize(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value
end

defmodule Tay.Bench.Observer do
  @moduledoc false
  use GenServer

  def start_link(limit), do: GenServer.start_link(__MODULE__, limit, name: __MODULE__)
  def note(message), do: GenServer.cast(__MODULE__, message)
  def result, do: GenServer.call(__MODULE__, :result)

  def init(limit),
    do:
      {:ok,
       %{
         jobs: %{},
         appends: %{},
         rotations: [],
         current: %{},
         calls: %{},
         last_segment: 1,
         limit: limit
       }}

  def handle_cast({:insert_begin, id, at, due, queue}, s),
    do: {:noreply, job(s, id, %{insert_begin: at, due: due, queue: queue})}

  def handle_cast({:insert_ack, id, at}, s),
    do: {:noreply, job(s, id, %{insert_ack: at})}

  def handle_cast({:entered, id, at, wall}, s),
    do: {:noreply, job(s, id, %{entered: at, entered_wall: wall})}

  def handle_cast({:returning, id, at}, s),
    do: {:noreply, job(s, id, %{returning: at})}

  def handle_cast({:holding, id, task}, s),
    do: {:noreply, job(s, id, %{task: task})}

  def handle_info({:trace_ts, engine, :call, {Tay.Engine, :commit, 4}, {type, raw}, _time}, s) do
    context = %{type: type, id: Tay.JobID.encode(raw)}
    {:noreply, %{s | current: Map.put(s.current, engine, context)}}
  end

  def handle_info({:trace_ts, engine, :call, {Tay.Storage.Writer, :append, 5}, time}, s) do
    {:noreply, %{s | current: Map.update!(s.current, engine, &Map.put(&1, :begin, time))}}
  end

  def handle_info(
        {:trace_ts, engine, :return_from, {Tay.Storage.Writer, :append, 5}, {:ok, receipt}, time},
        s
      ) do
    context = Map.fetch!(s.current, engine)
    elapsed = System.convert_time_unit(time - context.begin, :native, :microsecond)
    samples = Map.update(s.appends, context.type, [elapsed], &[elapsed | &1])

    rotations =
      if receipt.segment_id != s.last_segment, do: [elapsed | s.rotations], else: s.rotations

    point = if context.type == 4, do: :finished_receipt, else: :start_receipt

    s =
      if context.type in [3, 4],
        do: job(s, context.id, %{point => System.convert_time_unit(time, :native, :microsecond)}),
        else: s

    {:noreply, %{s | appends: samples, rotations: rotations, last_segment: receipt.segment_id}}
  end

  def handle_info({:trace_ts, _, :call, {module, function, arity}, _time}, s) do
    key = "#{inspect(module)}.#{function}/#{arity}"
    {:noreply, %{s | calls: Map.update(s.calls, key, 1, &(&1 + 1))}}
  end

  def handle_info(_, s), do: {:noreply, s}
  def handle_call(:result, _, s), do: {:reply, s, s}

  defp job(s, id, fields) do
    if not Map.has_key?(s.jobs, id) and map_size(s.jobs) >= s.limit,
      do: raise("benchmark observer exceeded its configured job bound")

    %{s | jobs: Map.update(s.jobs, id, fields, &Map.merge(&1, fields))}
  end
end

defmodule Tay.Bench.Worker do
  @moduledoc false
  use Tay.Worker, key: "tay.benchmark.v1", max_attempts: 1

  def perform(job) do
    Tay.Bench.Observer.note(
      {:entered, job.id, System.monotonic_time(:microsecond), System.system_time(:millisecond)}
    )

    # Bounded trusted no-op effect. The separate observer, not Tay history,
    # records callback entry; return values are not a durable result store.
    if job.args["hold"] == true do
      Tay.Bench.Observer.note({:holding, job.id, self()})

      receive do
        {:benchmark_release, id} when id == job.id -> :ok
      after
        60_000 -> exit(:benchmark_controller_timeout)
      end
    end

    Tay.Bench.Observer.note({:returning, job.id, System.monotonic_time(:microsecond)})
    :ok
  end
end

defmodule Tay.Bench.Memory do
  @moduledoc false
  def start(name, observer) do
    spawn(fn -> sample(name, observer, empty()) end)
  end

  def stop(pid) do
    ref = make_ref()
    send(pid, {:finish, self(), ref})

    receive do
      {^ref, result} -> result
    after
      5_000 -> raise("benchmark memory sampler did not finish")
    end
  end

  defp empty,
    do: %{
      samples: 0,
      beam_total_bytes: 0,
      beam_binary_bytes: 0,
      beam_ets_bytes: 0,
      engine_heap_bytes: 0,
      writer_heap_bytes: 0
    }

  defp sample(name, observer, peak) do
    memory = :erlang.memory()
    {engine, writer} = owners(name)

    current = %{
      beam_total_bytes: memory[:total],
      beam_binary_bytes: memory[:binary],
      beam_ets_bytes: memory[:ets],
      engine_heap_bytes: heap(engine),
      writer_heap_bytes: heap(writer)
    }

    peak =
      Enum.reduce(current, %{peak | samples: peak.samples + 1}, fn {key, value}, acc ->
        Map.update!(acc, key, &max(&1, value))
      end)

    receive do
      {:finish, caller, ref} -> send(caller, {ref, peak})
    after
      5 ->
        if Process.alive?(observer), do: sample(name, observer, peak)
    end
  end

  defp owners(name) do
    case Process.whereis(name) do
      nil ->
        {nil, nil}

      guardian ->
        try do
          state = :sys.get_state(guardian, 100)
          engine = Map.get(state, :engine)
          writer = Map.get(state, :writer) || linked_writer(engine)
          {engine, writer}
        catch
          :exit, _ -> {nil, nil}
        end
    end
  end

  defp linked_writer(engine) when is_pid(engine) do
    case Process.info(engine, :links) do
      {:links, links} ->
        Enum.find(links, fn pid ->
          is_pid(pid) and :proc_lib.translate_initial_call(pid) == {Tay.Storage.Writer, :init, 1}
        end)

      _ ->
        nil
    end
  end

  defp linked_writer(_), do: nil

  defp heap(pid) when is_pid(pid),
    do:
      case(Process.info(pid, :memory),
        do: (
          {:memory, bytes} -> bytes
          _ -> 0
        )
      )

  defp heap(_), do: 0
end

defmodule Tay.Bench.Harness do
  @moduledoc false
  alias Tay.Bench.{Stats, Observer, Worker, Memory}
  alias Tay.Storage.{Writer, Segment}
  @name Tay.Bench.Engine
  @defaults %{
    mode: :sync,
    validated_filesystem: false,
    jobs: 100,
    args_bytes: 1024,
    clients: 8,
    client_slots: 64,
    deadline_ms: 900_000,
    rotation_segments: 2,
    replay_segments: [1, 10, 100]
  }

  def options(options) when is_map(options) do
    c = Map.merge(@defaults, options)

    valid =
      Enum.all?(Map.keys(options), &(&1 in [:path | Map.keys(@defaults)])) and
        is_binary(c[:path]) and Path.type(c.path) == :absolute and
        c.mode in [:sync, :write] and is_boolean(c.validated_filesystem) and
        (c.mode != :sync or (c.validated_filesystem and :os.type() == {:unix, :linux})) and
        c.jobs in 1..100_000 and c.args_bytes in 0..262_000 and c.clients in 1..64 and
        c.client_slots in 1..65_536 and c.clients <= c.client_slots and
        c.deadline_ms in 1000..3_600_000 and c.rotation_segments in 2..100 and
        is_list(c.replay_segments) and c.replay_segments != [] and
        Enum.all?(c.replay_segments, &(&1 in 1..100)) and
        Enum.uniq(c.replay_segments) == c.replay_segments

    if valid, do: {:ok, c}, else: {:error, :invalid_benchmark_options}
  end

  def options(_), do: {:error, :invalid_benchmark_options}

  def run(scenario, supplied)
      when scenario in [:lifecycle, :rotation, :replay, :schedule, :reserve] do
    {:ok, c} = options(supplied)

    if File.exists?(c.path),
      do: raise("benchmark requires a new path; existing stores are never overwritten")

    ensure_application(c.path)
    {:ok, observer} = Observer.start_link(max(c.jobs, 10_000) + 1024)

    try do
      measurements = apply(__MODULE__, scenario, [c])

      %{
        report_schema: 1,
        scenario: scenario,
        measured_at_utc: DateTime.to_iso8601(DateTime.utc_now()),
        environment: environment(c),
        configuration: Map.delete(c, :path),
        measurements: measurements,
        guarantees:
          "Process/syscall measurements only; not power-loss certification or approved production capacity."
      }
    after
      if Process.alive?(observer), do: GenServer.stop(observer)
    end
  end

  def lifecycle(c) do
    initialize(c)
    {root, startup_us, owner_retries} = start(c)
    engine = engine(root)
    trace(engine)
    started = System.monotonic_time(:microsecond)

    try do
      ids = insert_many(c, c.jobs)
      Enum.each(ids, &await_completed(c, &1))
      elapsed = System.monotonic_time(:microsecond) - started
      state = :sys.get_state(engine)

      table_memory =
        Enum.sum(
          for table <- [state.projection.jobs, state.projection.queue, state.projection.schedule],
              do: :ets.info(table, :memory) * :erlang.system_info(:wordsize)
        )

      flush_trace(engine)
      measurements = observed(Observer.result())
      status = stable_status()
      stop(root)
      {:ok, replay_root, replay} = measured_restart(c)
      stop(replay_root)
      bytes = canonical_bytes(c.path)

      Map.merge(measurements, %{
        jobs: length(ids),
        total_elapsed_us: elapsed,
        completed_jobs_per_second: length(ids) * 1_000_000 / elapsed,
        startup_us: startup_us,
        startup_owner_retries: owner_retries,
        canonical_bytes: bytes,
        bytes_per_completed_job: bytes / length(ids),
        ready_private_ets_bytes: table_memory,
        status: status,
        restart: replay
      })
    after
      untrace(engine)
      stop(root)
    end
  end

  def rotation(c) do
    initialize(c)
    {root, startup_us, retries} = start(c, rotation_target_bytes: Segment.min_rotation_bytes())
    pid = engine(root)
    trace(pid)
    c = %{c | args_bytes: 262_000}

    try do
      inserted = fill_segments(c, root, 0)
      flush_trace(pid)
      result = observed(Observer.result())
      status = stable_status()
      stop(root)

      Map.merge(result, %{
        kind: :organic_threshold_rotation,
        target_segment_count: c.rotation_segments,
        actual_segment_count: canonical_count(c.path),
        inserted_jobs: inserted,
        args_body_bytes: c.args_bytes,
        startup_us: startup_us,
        startup_owner_retries: retries,
        canonical_bytes: canonical_bytes(c.path),
        status: status,
        caveat:
          "p95/p99 use nearest rank; inspect sample count. A few rotations are measurements, not a tail-latency guarantee."
      })
    after
      untrace(pid)
      stop(root)
    end
  end

  defp fill_segments(c, root, count) do
    if :sys.get_state(engine(root)).segment.id >= c.rotation_segments do
      count
    else
      if count >= c.rotation_segments * 100,
        do: raise("organic rotation did not reach its bounded target")

      insert_one(c, count, System.system_time(:millisecond) + 86_400_000)
      fill_segments(c, root, count + 1)
    end
  end

  def replay(c) do
    # Explicitly compact topology fixtures: legal Events and real Writer
    # barriers/rotations, not artificially lowered organic rotation thresholds.
    File.mkdir!(c.path)

    Enum.map(c.replay_segments, fn segments ->
      fixture = %{c | path: Path.join(c.path, "segments-#{segments}")}
      build_compact(fixture, segments)
      :erlang.garbage_collect()
      {:ok, root, memory} = measured_restart(fixture)
      status = stable_status()
      stop(root)

      Map.merge(memory, %{
        kind: :compact_manually_rotated_history,
        segments: segments,
        jobs: segments,
        canonical_bytes: canonical_bytes(fixture.path),
        status: status,
        caveat:
          "Topology/replay measurement only: one job per segment, not organic full-segment throughput or a maximum-byte capacity claim."
      })
    end)
  end

  def schedule(c) do
    initialize(c)
    {root, _, _} = start(c)
    pid = engine(root)
    trace(pid)

    try do
      idle_due = System.system_time(:millisecond) + 100
      idle = for index <- 1..min(c.jobs, 20), do: insert_one(c, index, idle_due)
      Enum.each(idle, &await_completed(c, &1))
      saturated_due = System.system_time(:millisecond) + 100
      saturated_due_monotonic = wall_to_monotonic_us(saturated_due)
      probes = for index <- 1..min(c.jobs, 20), do: insert_one(c, index, saturated_due)
      counter = :atomics.new(1, [])
      parent = self()

      loaders =
        for index <- 1..c.clients do
          Task.async(fn -> load(c, counter, index, parent, %{accepted: 0, refused: 0}) end)
        end

      # The external receipt observer does not compete for client permits while
      # the load clients occupy them. Query reads happen after load shutdown.
      Enum.each(probes, &await_finished_receipt(c, &1))
      Enum.each(loaders, &send(&1.pid, :stop))
      load_counts = Enum.map(loaders, &Task.await(&1, c.deadline_ms))
      Enum.each(probes, &await_completed(c, &1))
      flush_trace(pid)
      facts = Observer.result()
      result = observed(facts)
      idle_lags = lags(facts, idle)
      saturated_lags = lags(facts, probes)
      load_jobs = Map.drop(facts.jobs, idle ++ probes)

      overlapping =
        Enum.count(load_jobs, fn {_, j} ->
          j[:insert_begin] && j[:insert_ack] &&
            j.insert_begin <= saturated_due_monotonic &&
            j.insert_ack >= saturated_due_monotonic
        end)

      status = stable_status()
      stop(root)

      Map.merge(result, %{
        idle_schedule_lag_ms: Stats.distribution(idle_lags),
        insertion_load_schedule_lag_ms: Stats.distribution(saturated_lags),
        idle_queue_lag_ms: queue_lags(facts, idle),
        insertion_load_queue_lag_ms: queue_lags(facts, probes),
        load_insertions: Enum.sum(Enum.map(load_counts, & &1.accepted)),
        load_client_slot_refusals: Enum.sum(Enum.map(load_counts, & &1.refused)),
        insert_calls_overlapping_probe_due: overlapping,
        saturated_label_proven: overlapping >= c.clients,
        canonical_bytes: canonical_bytes(c.path),
        status: status,
        caveat:
          "Call overlap is observed, not assumed. If saturated_label_proven=false, this run is insertion-load lag only, not a saturated-load qualification."
      })
    after
      untrace(pid)
      stop(root)
    end
  end

  def reserve(c) do
    initialize(c)
    limit = 3_000
    {root, _, _} = start(c, max_history_bytes: limit)
    pid = engine(root)
    trace(pid)

    try do
      {:ok, holding} = Worker.new(%{"hold" => true}, queue: :alpha, timeout_ms: 60_000)
      Observer.note({:insert_begin, holding.id, System.monotonic_time(:microsecond), nil, :alpha})
      {:ok, _} = Tay.insert(holding, name: @name, timeout: c.deadline_ms)
      Observer.note({:insert_ack, holding.id, System.monotonic_time(:microsecond)})
      task = await_holding(holding.id, System.monotonic_time(:millisecond) + 5_000)
      active = stable_status()
      {inserted, refusal, before_refusal} = fill_budget(c, 0)
      after_refusal = stable_status()

      if after_refusal.canonical_history_bytes != before_refusal.canonical_history_bytes,
        do: raise("capacity refusal changed canonical history")

      send(task, {:benchmark_release, holding.id})
      await_completed(c, holding.id)
      flush_trace(pid)
      final = stable_status()

      if final.canonical_history_bytes > limit or final.reserved_outcome_bytes != 0,
        do: raise("reserved outcome did not settle within the configured history budget")

      Map.merge(observed(Observer.result()), %{
        kind: :real_admission_reserve_exhaustion,
        max_history_bytes: limit,
        inserted_future_jobs: inserted,
        refusal: Map.take(refusal, [:kind, :reason]),
        active_status: active,
        refused_status: after_refusal,
        settled_status: final,
        canonical_bytes: canonical_bytes(c.path),
        scope:
          "Logical admission headroom only; not a free-disk guarantee, fault simulation, or protection against ENOSPC/repeated crashes."
      })
    after
      untrace(pid)
      stop(root)
    end
  end

  defp fill_budget(c, count) when count < 100 do
    {:ok, job} =
      Worker.new(%{"payload" => String.duplicate("x", 128)},
        queue: :beta,
        scheduled_at: System.system_time(:millisecond) + 86_400_000
      )

    before = stable_status()

    case Tay.insert(job, name: @name, timeout: c.deadline_ms) do
      {:ok, _} ->
        fill_budget(c, count + 1)

      {:error, %Tay.Error{kind: :capacity, reason: :max_history_bytes} = error} ->
        {count, error, before}

      other ->
        raise("unexpected capacity result: #{inspect(other, limit: 5)}")
    end
  end

  defp fill_budget(_, _), do: raise("capacity scenario did not reach its bounded refusal")

  defp await_holding(id, deadline) do
    case Observer.result().jobs[id] do
      %{task: task} ->
        task

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("benchmark holding worker did not enter")

        receive do
        after
          2 -> await_holding(id, deadline)
        end
    end
  end

  defp stable_status do
    # Public status is deliberately a bounded asynchronous snapshot. Measurement
    # boundaries wait for its acknowledged counters, never treat a stale snapshot
    # as proof of a lost event or of a successful capacity refusal.
    state = :sys.get_state(:sys.get_state(Process.whereis(@name)).engine)

    expected = {
      state.history_bytes,
      state.active_budget.count + state.terminal_budget.count,
      state.settlement_reserve
    }

    stable_status(expected, System.monotonic_time(:millisecond) + 5_000)
  end

  defp stable_status(expected, deadline) do
    value = Tay.status(name: @name)
    actual = {value.canonical_history_bytes, value.jobs, value.unsettled_executions}

    if actual == expected do
      value
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("benchmark status snapshot did not converge at a quiescent boundary")

      receive do
      after
        2 -> stable_status(expected, deadline)
      end
    end
  end

  defp load(c, counter, index, parent, count) do
    receive do
      :stop -> count
    after
      0 ->
        ordinal = :atomics.add_get(counter, 1, 1)

        if ordinal > 10_000 do
          count
        else
          result =
            insert_one(c, ordinal + index, System.system_time(:millisecond) + 86_400_000, true)

          count =
            case result do
              {:refused, :client_slots} ->
                receive do
                after
                  1 -> :ok
                end

                %{count | refused: count.refused + 1}

              id when is_binary(id) ->
                %{count | accepted: count.accepted + 1}
            end

          if Process.alive?(parent),
            do: load(c, counter, index, parent, count),
            else: count
        end
    end
  end

  defp lags(facts, ids),
    do: Enum.map(ids, fn id -> facts.jobs[id].entered_wall - facts.jobs[id].due end)

  defp queue_lags(facts, ids) do
    ids
    |> Enum.group_by(&facts.jobs[&1].queue, fn id ->
      facts.jobs[id].entered_wall - facts.jobs[id].due
    end)
    |> Map.new(fn {queue, values} -> {queue, Stats.distribution(values)} end)
  end

  defp await_finished_receipt(c, id) when is_map(c),
    do: await_finished_receipt(id, System.monotonic_time(:millisecond) + c.deadline_ms)

  defp await_finished_receipt(id, deadline) when is_binary(id) do
    if is_integer(Observer.result().jobs[id][:finished_receipt]) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("benchmark observed finish deadline exceeded")

      receive do
      after
        5 -> await_finished_receipt(id, deadline)
      end
    end
  end

  defp wall_to_monotonic_us(wall), do: wall * 1000 - System.time_offset(:microsecond)

  defp insert_many(c, count) do
    1..count
    |> Task.async_stream(&insert_one(c, &1, nil),
      max_concurrency: c.clients,
      ordered: false,
      timeout: c.deadline_ms
    )
    |> Enum.map(fn {:ok, id} -> id end)
  end

  defp insert_one(c, index, due, observe_slot_refusal \\ false) do
    queue = if rem(index, 2) == 0, do: :alpha, else: :beta

    args = %{
      "account_key" => "benchmark-account",
      "payload" => String.duplicate("x", c.args_bytes),
      "version" => 1
    }

    {:ok, job} = Worker.new(args, queue: queue, scheduled_at: due)
    Observer.note({:insert_begin, job.id, System.monotonic_time(:microsecond), due, queue})

    case Tay.insert(job, name: @name, timeout: c.deadline_ms) do
      {:ok, _} ->
        Observer.note({:insert_ack, job.id, System.monotonic_time(:microsecond)})
        job.id

      {:error, %Tay.Error{kind: :capacity, reason: :client_slots}} when observe_slot_refusal ->
        # Known pre-I/O refusal, counted separately. This logical request is not
        # retried; no unknown-outcome request is silently replaced or repeated.
        {:refused, :client_slots}

      {:error, error} ->
        raise("benchmark insertion refused: #{inspect(error, limit: 6, printable_limit: 120)}")
    end
  end

  defp await_completed(c, id),
    do: await_completed(c, id, System.monotonic_time(:millisecond) + c.deadline_ms)

  defp await_completed(c, id, deadline) do
    case Tay.get_job(id, name: @name, timeout: min(c.deadline_ms, 30_000)) do
      {:ok, %{state: :completed}} ->
        :ok

      {:ok, %{state: state}} when state in [:scheduled, :available, :executing] ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("benchmark completion deadline exceeded")

        receive do
        after
          5 -> await_completed(c, id, deadline)
        end

      other ->
        raise("benchmark job did not complete: #{inspect(other, limit: 5, printable_limit: 80)}")
    end
  end

  defp initialize(c) do
    case Tay.Storage.initialize(storage(c)) do
      {:ok, _} -> :ok
      error -> raise("benchmark initialization failed: #{inspect(error, limit: 6)}")
    end
  end

  defp storage(c),
    do: [data_dir: c.path, durability: c.mode, validated_filesystem: c.validated_filesystem]

  defp engine_options(c) do
    storage(c) ++
      [
        name: @name,
        workers: %{"tay.benchmark.v1" => Worker},
        queues: [alpha: 2, beta: 2],
        client_slots: c.client_slots,
        caller_timeout: c.deadline_ms,
        execution_wake_ms: 50,
        recovery: [deadline_ms: c.deadline_ms, activation_deadline_ms: c.deadline_ms]
      ]
  end

  defp start(c, extra \\ []) do
    started = System.monotonic_time(:microsecond)
    start_until(Keyword.merge(engine_options(c), extra), started, started + 5_000_000, 0)
  end

  defp start_until(options, started, deadline, retries) do
    case Tay.start_link(options) do
      {:ok, root} ->
        {root, System.monotonic_time(:microsecond) - started, retries}

      error ->
        if ownership_busy?(error) and System.monotonic_time(:microsecond) < deadline do
          receive do
          after
            5 -> start_until(options, started, deadline, retries + 1)
          end
        else
          raise("benchmark startup refused: #{inspect(error, limit: 8, printable_limit: 120)}")
        end
    end
  end

  defp ownership_busy?({:error, value}), do: ownership_busy?(value)
  defp ownership_busy?({:shutdown, value}), do: ownership_busy?(value)
  defp ownership_busy?({:failed_to_start_child, _, value}), do: ownership_busy?(value)
  defp ownership_busy?(%Tay.Error{reason: {:recovery, value}}), do: ownership_busy?(value)
  defp ownership_busy?(%Tay.Storage.Recovery.Error{kind: :ownership_busy}), do: true

  defp ownership_busy?(%Tay.Error{reason: reason})
       when reason in [:local_tasks_terminating, :local_generation_owned], do: true

  defp ownership_busy?(_), do: false

  defp stop(root) do
    if is_pid(root) and Process.alive?(root), do: Supervisor.stop(root, :normal, :infinity)
    :ok
  end

  defp engine(root),
    do:
      Enum.find_value(Supervisor.which_children(root), fn {id, pid, _, _} ->
        if id == Tay.Engine, do: pid
      end)

  defp measured_restart(c) do
    baseline = :erlang.memory() |> Map.new()
    sampler = Memory.start(@name, self())

    try do
      {root, elapsed, retries} = start(c)
      memory = Memory.stop(sampler)

      {:ok, root,
       %{
         elapsed_us: elapsed,
         owner_release_retries: retries,
         configured_recovery_deadline_ms: c.deadline_ms,
         within_configured_deadline: elapsed <= c.deadline_ms * 1000,
         sampled_peak: memory,
         baseline_beam_bytes: baseline.total,
         sampled_peak_delta_bytes: max(memory.beam_total_bytes - baseline.total, 0),
         memory_caveat:
           "5ms samples are observed peaks, not a proven upper bound; BEAM totals include observer/runtime, process heap excludes shared binary backing."
       }}
    catch
      kind, reason ->
        Memory.stop(sampler)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp build_compact(c, segments) do
    initialize(c)
    writer = open_writer(c, System.monotonic_time(:millisecond) + 5000)

    try do
      for index <- 1..segments do
        at = System.system_time(:millisecond)

        {:ok, job} =
          Worker.new(
            %{
              "account_key" => "replay-fixture",
              "payload" => String.duplicate("x", c.args_bytes)
            },
            queue: :alpha,
            scheduled_at: at + 86_400_000
          )

        {:ok, raw} = Tay.JobID.decode(job.id)

        event = %Tay.Event{
          record_type: 1,
          data: %{
            "at" => at,
            "definition" => job.definition,
            "eligible_at" => job.definition["scheduled_at"],
            "expected_revision" => 0,
            "job_id" => raw
          }
        }

        {:ok, {type, schema, payload}} = Tay.Event.encode(event)
        {:ok, prepared} = Tay.State.Transition.prepare(nil, event)
        {:ok, receipt} = Writer.append(writer, type, schema, payload)
        {:ok, _} = Tay.State.Transition.apply(prepared, receipt)
        if index < segments, do: {:ok, _} = Writer.rotate(writer)
      end
    after
      if Process.alive?(writer), do: GenServer.stop(writer)
    end
  end

  defp open_writer(c, deadline) do
    case Writer.start_link(storage(c)) do
      {:ok, writer} ->
        writer

      {:error, %{reason: "store_busy"}} ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("fixture owner did not release")

        receive do
        after
          5 -> open_writer(c, deadline)
        end

      error ->
        raise("fixture Writer refused: #{inspect(error, limit: 8)}")
    end
  end

  defp trace(engine) do
    # Arity-only tracing with a bounded {type, 16-byte-ID} message: no args,
    # payload bytes, private Engine return state or native handles are traced.
    pattern = [
      {[:_, :_, %{record_type: :"$1", data: %{"job_id" => :"$2"}}, :_], [],
       [{:message, {{:"$1", :"$2"}}}]}
    ]

    :erlang.trace_pattern({Tay.Engine, :commit, 4}, pattern, [:local])
    :erlang.trace_pattern({Writer, :append, 5}, [{:_, [], [{:return_trace}]}], [:local])

    for module <- [
          Tay.State.JobIndex,
          Tay.State.QueueIndex,
          Tay.State.SchedulerIndex,
          Tay.Storage.Reader
        ],
        do: :erlang.trace_pattern({module, :_, :_}, true, [:local])

    :erlang.trace(engine, true, [
      :call,
      :arity,
      :monotonic_timestamp,
      {:tracer, Process.whereis(Observer)}
    ])

    writer = :sys.get_state(engine).writer
    Process.put({__MODULE__, :traced_writer}, writer)

    :erlang.trace(writer, true, [
      :call,
      :arity,
      :monotonic_timestamp,
      {:tracer, Process.whereis(Observer)}
    ])
  end

  defp untrace(engine) do
    safe_untrace(engine)
    writer = Process.delete({__MODULE__, :traced_writer})
    safe_untrace(writer)

    for module <- [
          Tay.Engine,
          Writer,
          Tay.State.JobIndex,
          Tay.State.QueueIndex,
          Tay.State.SchedulerIndex,
          Tay.Storage.Reader
        ],
        do: :erlang.trace_pattern({module, :_, :_}, false, [:local])
  end

  defp safe_untrace(pid) when is_pid(pid) do
    # A traced process may exit between Process.alive?/1 and trace/3 during
    # cleanup; that death is not a benchmark or storage failure.
    :erlang.trace(pid, false, [:all])
  rescue
    ArgumentError -> :ok
  end

  defp safe_untrace(_), do: :ok

  defp flush_trace(engine) do
    for pid <- [engine, Process.get({__MODULE__, :traced_writer})], is_pid(pid) do
      ref = :erlang.trace_delivered(pid)

      receive do
        {:trace_delivered, ^pid, ^ref} -> :ok
      after
        5000 -> raise("benchmark trace delivery deadline exceeded")
      end
    end
  end

  defp observed(facts) do
    delta = fn first, last ->
      facts.jobs
      |> Map.values()
      |> Enum.filter(&(is_integer(&1[first]) and is_integer(&1[last])))
      |> Enum.map(&(&1[last] - &1[first]))
      |> Stats.distribution()
    end

    queues =
      facts.jobs
      |> Map.values()
      |> Enum.filter(&Map.has_key?(&1, :entered))
      |> Enum.frequencies_by(& &1.queue)

    %{
      insert_roundtrip_us: delta.(:insert_begin, :insert_ack),
      start_receipt_to_callback_us: delta.(:start_receipt, :entered),
      worker_return_to_finish_receipt_us: delta.(:returning, :finished_receipt),
      physical_append_receipt_us:
        Map.new(facts.appends, fn {type, values} ->
          {Integer.to_string(type), Stats.distribution(values)}
        end),
      organic_rotation_append_us: Stats.distribution(facts.rotations),
      callback_counts_by_queue: queues,
      indexed_call_counts: facts.calls,
      tracing:
        "Local arity-only call tracing is enabled; timings include instrumentation overhead. Append receipts include mode-specific I/O barriers, not subsequent projection/reply."
    }
  end

  defp canonical_files(path),
    do:
      File.ls!(Path.join(path, "segments"))
      |> Enum.filter(&match?({:ok, _}, Segment.filename_id(&1)))

  defp canonical_count(path), do: length(canonical_files(path))

  defp canonical_bytes(path),
    do:
      Enum.sum(
        for file <- canonical_files(path),
            do: File.stat!(Path.join([path, "segments", file])).size
      )

  defp ensure_application(path) do
    if is_nil(Process.whereis(Tay.Supervisor)), do: Application.put_env(:tay, :data_dir, path)
    {:ok, _} = Application.ensure_all_started(:tay)
  end

  defp environment(c) do
    filesystem =
      case :os.type() do
        {:unix, :linux} ->
          {value, 0} = System.cmd("stat", ["-f", "-c", "%T", Path.dirname(c.path)])
          String.trim(value)

        {:unix, :darwin} ->
          "macOS development filesystem; no strict-sync qualification"

        other ->
          inspect(other)
      end

    %{
      elixir: System.version(),
      otp: System.otp_release(),
      operating_system: inspect(:os.type()),
      schedulers: :erlang.system_info(:schedulers_online),
      word_bytes: :erlang.system_info(:wordsize),
      filesystem: filesystem,
      durability: c.mode,
      validated_filesystem_assertion: c.validated_filesystem
    }
  end
end
