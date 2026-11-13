defmodule Tay.Engine.IncrementalCheckpointTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers, RecoveryHelpers}
  alias Tay.Storage.Native
  alias Tay.Test.{ExecutionClock, ExecutionHelpers}
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  @tag timeout: 120_000
  test "whole-VM SIGKILL preserves shared archives and acknowledged incremental tails", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    {:ok, intent} = EngineWorker.new(%{"shared_archive" => String.duplicate("v", 4_000)})
    {:ok, archived} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(archived.id, name: @name, expected_revision: archived.revision)
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)

    script = """
    Code.prepend_path(#{inspect(Application.app_dir(:stream_data, "ebin"))})
    {:ok, _} = Application.ensure_all_started(:tay)
    [path, site] = System.argv()
    site = Enum.find([:v2_publish_epoch, :v2_epoch_parent_sync, :v2_publish_current,
      :v2_current_root_sync], &(Atom.to_string(&1) == site))
    name = Tay.Test.IncrementalCrash
    {:ok, _} = Tay.Test.EngineHelpers.restart(path, name, compaction: false)
    writer = :sys.get_state(name).writer
    :ok = Tay.Storage.Writer.inject_fault(writer, site, 1, :vm_crash_after)
    IO.puts("ARMED:" <> Atom.to_string(site))
    Tay.compact(name: name, terminal_retention: :infinity, timeout: 60_000)
    IO.puts("UNREACHED")
    """

    for site <- [
          :v2_publish_epoch,
          :v2_epoch_parent_sync,
          :v2_publish_current,
          :v2_current_root_sync
        ] do
      {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
      {:ok, intent} = EngineWorker.new(%{"acknowledged_before_sigkill" => Atom.to_string(site)})
      {:ok, tail} = Tay.insert(intent, name: @name)
      EngineHelpers.stop(root)
      {output, exit_code} = NativeHelpers.child_elixir(script, [path, Atom.to_string(site)])
      assert exit_code != 0, output
      assert output =~ "ARMED:#{site}", output
      refute output =~ "UNREACHED", output
      {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
      assert {:ok, %{state: :cancelled}} = Tay.get_job(archived.id, name: @name)
      assert {:ok, %{args: args}} = Tay.get_job(tail.id, name: @name)
      assert args == intent.args
      EngineHelpers.stop(root)
    end
  end

  test "cold lookups wait for a delegated reader and continue during preparation", %{path: path} do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    {:ok, intent} = EngineWorker.new(%{"cold" => String.duplicate("c", 1_000)})
    {:ok, job} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    writer = :sys.get_state(@name).writer

    on_exit(fn ->
      send(writer, :release_reader)
      EngineHelpers.stop(root)
    end)

    owner = self()
    gate = :atomics.new(1, [])

    :sys.install(
      writer,
      {fn state, event, _ ->
         case event do
           {:in, {:"$gen_call", _, {:tay_native_request, _, _, :read, _}}} ->
             if :atomics.compare_exchange(gate, 1, 0, 1) == :ok do
               send(owner, {:reader_open, self()})
               receive do: (:release_reader -> :ok)
             end

           _ ->
             :ok
         end

         state
       end, nil}
    )

    compact = Task.async(fn -> Tay.compact(name: @name, terminal_retention: :infinity) end)
    assert_receive {:reader_open, ^writer}, 5_000
    lookup = Task.async(fn -> Tay.get_job(job.id, name: @name) end)

    assert EngineHelpers.eventually(fn ->
             {:messages, messages} = Process.info(writer, :messages)
             Enum.any?(messages, &match?({:"$gen_call", _, {:checkpoint_job, _, _, _, _}}, &1))
           end)

    send(writer, :release_reader)
    assert {:ok, recovered} = Task.await(lookup, 10_000)
    assert recovered.args == intent.args
    assert {:ok, _} = Task.await(compact, 60_000)
    assert Tay.status(name: @name).state == :ready
    EngineHelpers.stop(root)
  end

  @tag capture_log: true
  test "incremental publication faults retain archived and acknowledged tail jobs", %{path: path} do
    for {operation, action, errno} <- [
          {:write, :error, 28},
          {:write, :short, 5},
          {:sync, :crash_after, 5},
          {:v2_publish_epoch, :crash_after, 5},
          {:v2_publish_current, :crash_before, 5},
          {:v2_publish_current, :drop_reply, 5},
          {:v2_current_root_sync, :crash_after, 5}
        ] do
      {:ok, root} = EngineHelpers.restart(path, @name, compaction: false, storage_timeout: 300)
      {:ok, intent} = EngineWorker.new(%{"fault_archive" => Atom.to_string(operation)})
      {:ok, job} = Tay.insert(intent, name: @name)
      {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
      assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
      {:ok, intent2} = EngineWorker.new(%{"acknowledged_tail" => Atom.to_string(action)})
      {:ok, tail_job} = Tay.insert(intent2, name: @name)
      writer = :sys.get_state(@name).writer
      assert :ok = Tay.Storage.Writer.inject_fault(writer, operation, 1, action, errno)
      _ = Tay.compact(name: @name, terminal_retention: :infinity, timeout: 60_000)
      EngineHelpers.stop(root)
      {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
      assert {:ok, %{args: args}} = Tay.get_job(job.id, name: @name)
      assert args == intent.args
      assert {:ok, %{args: args}} = Tay.get_job(tail_job.id, name: @name)
      assert args == intent2.args
      EngineHelpers.stop(root)
    end
  end

  test "finite retention repacks a sparse segment and reclaims only unreachable data", %{
    path: path
  } do
    ExecutionHelpers.install(0)

    {:ok, root} =
      EngineHelpers.restart(path, @name, compaction: false, test_clock: ExecutionClock)

    args = %{"body" => String.duplicate("s", 20_000)}

    old =
      for _ <- 1..9 do
        {:ok, intent} = EngineWorker.new(args)
        {:ok, job} = Tay.insert(intent, name: @name)
        {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
        job.id
      end

    ExecutionHelpers.set_clock(3_600_000)
    {:ok, intent} = EngineWorker.new(args)
    {:ok, kept} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(kept.id, name: @name, expected_revision: kept.revision)
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    archive = RecoveryHelpers.canonical(path, 1)
    ExecutionHelpers.set_clock(3_600_100)
    assert {:ok, stats} = Tay.compact(name: @name, terminal_retention: {:hours, 1})
    assert stats.expired_jobs == 9
    assert stats.retained_terminal_jobs == 1
    assert stats.cleaned_segments == 1
    assert stats.cleaned_source_bytes > 200_000
    assert stats.reused_bytes == 0
    assert EngineHelpers.eventually(fn -> not File.exists?(archive) end)
    assert {:ok, recovered} = Tay.get_job(kept.id, name: @name)
    assert recovered.args == args
    for id <- old, do: assert({:error, :not_found} = Tay.get_job(id, name: @name))
    EngineHelpers.stop(root)

    {:ok, root} =
      EngineHelpers.restart(path, @name, compaction: false, test_clock: ExecutionClock)

    assert {:ok, %{args: ^args}} = Tay.get_job(kept.id, name: @name)
    assert Tay.status(name: @name).jobs == 1
    EngineHelpers.stop(root)
  end

  test "a changed tail reuses the archive and changes only affected index pages", %{path: path} do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    args = %{"body" => String.duplicate("x", 64_000)}

    ids =
      for _ <- 1..200 do
        {:ok, intent} = EngineWorker.new(args)
        {:ok, job} = Tay.insert(intent, name: @name)
        {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
        job.id
      end

    assert {:ok, first} = Tay.compact(name: @name, terminal_retention: :infinity, timeout: 60_000)
    assert first.recovered.manifest.recovery_index.format == 2
    {:ok, intent} = EngineWorker.new(%{"new" => "tail"})
    {:ok, added} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(added.id, name: @name, expected_revision: added.revision)
    writer = :sys.get_state(@name).writer

    :erlang.trace_pattern(
      {Native, :read, 3},
      [{[:_, :_, :"$1"], [], [{:message, {{:read_bytes, :"$1"}}}]}],
      [:local]
    )

    :erlang.trace(writer, true, [:call, :arity, :set_on_spawn, {:tracer, self()}])

    try do
      assert {:ok, second} =
               Tay.compact(name: @name, terminal_retention: :infinity, timeout: 60_000)

      :erlang.trace(writer, false, [:all])
      assert second.recovered.incremental
      assert map_size(second.recovered.candidate.jobs) == 1
      assert second.retained_terminal_jobs == 201
      assert second.reused_bytes > 12_000_000
      assert second.rewritten_bytes < 1_000_000
      bytes_read = read_bytes()
      assert bytes_read > 0
      assert bytes_read < 1_000_000
      assert {:ok, retained} = Tay.get_job(hd(ids), name: @name)
      assert retained.args == args
      assert {:ok, _} = Tay.get_job(added.id, name: @name)
      EngineHelpers.stop(root)
      {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
      assert {:ok, retained} = Tay.get_job(hd(ids), name: @name)
      assert retained.args == args
      assert {:ok, _} = Tay.get_job(added.id, name: @name)
      assert EngineHelpers.eventually(fn -> Tay.status(name: @name).jobs == 201 end)
      EngineHelpers.stop(root)
    after
      if Process.alive?(writer), do: :erlang.trace(writer, false, [:all])
      :erlang.trace_pattern({Native, :read, 3}, false, [:local])
      EngineHelpers.stop(root)
    end
  end

  test "backup and restore preserve referenced archives across checkpoint generations", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    {:ok, intent} = EngineWorker.new(%{"archive" => String.duplicate("b", 8_000)})
    {:ok, job} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)
    backup = path <> "-backup"
    restored = path <> "-restored"
    catalog = path <> "-catalog.json"
    restored_catalog = path <> "-restored.json"
    sync? = System.get_env("TAY_TEST_SYNC") == "1"
    mode = if sync?, do: :sync, else: :development
    on_exit(fn -> Enum.each([backup, restored, catalog, restored_catalog], &File.rm_rf!/1) end)

    assert {:ok, _} =
             Tay.Storage.ColdCopy.backup(
               source: path,
               destination: backup,
               catalog: catalog,
               durability: mode,
               validated_filesystem: sync?
             )

    assert {:ok, _} =
             Tay.Storage.ColdCopy.restore(
               source: backup,
               destination: restored,
               catalog: restored_catalog,
               verify_catalog: catalog,
               durability: mode,
               validated_filesystem: sync?
             )

    {:ok, root} = EngineHelpers.restart(restored, @name, compaction: false)
    assert {:ok, recovered} = Tay.get_job(job.id, name: @name)
    assert recovered.args == intent.args
    EngineHelpers.stop(root)
  end

  defp read_bytes(sum \\ 0) do
    receive do
      {:trace, _, :call, {Native, :read, 3}, {:read_bytes, bytes}} -> read_bytes(sum + bytes)
      {:trace, _, _, _} -> read_bytes(sum)
    after
      0 -> sum
    end
  end
end
