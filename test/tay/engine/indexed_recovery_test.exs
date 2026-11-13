defmodule Tay.Engine.IndexedRecoveryTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers, RecoveryHelpers}
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "startup keeps cold arguments on disk and preserves duplicate/retry semantics", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    args = %{"body" => String.duplicate("x", 250_000)}
    {:ok, intent} = EngineWorker.new(args)
    {:ok, job} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)
    {:ok, restarted} = EngineHelpers.restart(path, @name, compaction: false)
    engine = :sys.get_state(@name).engine
    # Published history remains in the authenticated index; restart does not
    # rebuild a disposable DETS copy of every terminal identifier.
    store = :sys.get_state(engine).terminal_store
    {:ok, raw} = Tay.JobID.decode(intent.id)
    assert :dets.lookup(store.table, raw) == []
    assert store.backend
    assert {:ok, restored} = Tay.get_job(job.id, name: @name)
    assert restored.definition["args"] == args
    assert {:ok, duplicate} = Tay.insert(intent, name: @name)
    assert duplicate.id == restored.id
    # The new capability resolves the retained summary through shared archive roots.
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    assert {:ok, rebased} = Tay.get_job(job.id, name: @name)
    assert rebased.args == args

    assert {:error, %{kind: :conflict}} =
             Tay.retry(job.id, name: @name, expected_revision: restored.revision)

    EngineHelpers.stop(restarted)
    {:ok, again} = EngineHelpers.restart(path, @name, compaction: false)
    assert {:ok, unchanged} = Tay.get_job(job.id, name: @name)
    assert unchanged.definition["args"] == args
    assert unchanged.state == :cancelled
    EngineHelpers.stop(again)
  end

  defmodule FailedWorker do
    use Tay.Worker, key: "indexed.failed.v1"
    def perform(_), do: {:error, :expected}
  end

  test "discarded cold job is hydrated before a retry in the recovered tail", %{path: path} do
    options = [
      compaction: false,
      test_execution: true,
      workers: %{"indexed.failed.v1" => FailedWorker}
    ]

    {:ok, root} = EngineHelpers.restart(path, @name, options)
    args = %{"body" => String.duplicate("z", 10_000)}
    {:ok, intent} = FailedWorker.new(args, max_attempts: 1)
    {:ok, _} = Tay.insert(intent, name: @name)

    assert EngineHelpers.eventually(fn ->
             match?({:ok, %{state: :discarded}}, Tay.get_job(intent.id, name: @name))
           end)

    assert :ok = Tay.pause_queue(:default, name: @name)
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)
    options = Keyword.put(options, :start_paused, true)
    {:ok, root} = EngineHelpers.restart(path, @name, options)
    {:ok, discarded} = Tay.get_job(intent.id, name: @name)
    assert {:ok, _} = Tay.retry(intent.id, name: @name, expected_revision: discarded.revision)
    EngineHelpers.stop(root)
    {:ok, root} = EngineHelpers.restart(path, @name, options)
    assert {:ok, retried} = Tay.get_job(intent.id, name: @name)
    assert retried.state == :available
    assert retried.args == args
    EngineHelpers.stop(root)
  end

  test "unchanged checkpoint retains referenced archives and reports the full pause", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    {:ok, intent} = EngineWorker.new(%{"body" => String.duplicate("a", 10_000)})
    {:ok, job} = Tay.insert(intent, name: @name)
    assert {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    assert {:ok, first} = Tay.compact(name: @name, terminal_retention: :infinity)
    old_segment = RecoveryHelpers.canonical(path, 1)
    old_bytes = File.read!(old_segment)
    old_inode = File.stat!(old_segment).inode
    engine = :sys.get_state(@name).engine

    :sys.install(
      engine,
      {fn state, event, _ ->
         case event do
           {:in, {:compact_online_result, _, _, {:ok, _, _}}} -> Process.sleep(60)
           _ -> :ok
         end

         state
       end, nil}
    )

    assert {:ok, second} = Tay.compact(name: @name, terminal_retention: :infinity)
    assert second.previous_epoch_id == first.epoch_id
    assert second.pause_ms >= second.publication_pause_ms + 50
    assert second.total_ms >= second.publication_total_ms + 50
    assert second.rewritten_bytes + second.reused_bytes == second.candidate_bytes
    assert second.reused_bytes > 0
    new_segment = RecoveryHelpers.canonical(path, 1)
    assert byte_size(File.read!(new_segment)) == 44
    assert File.read!(old_segment) == old_bytes
    assert File.stat!(old_segment).inode == old_inode
    assert {:ok, restored} = Tay.get_job(intent.id, name: @name)
    assert restored.args == intent.args
    EngineHelpers.stop(root)
  end

  @tag capture_log: true
  test "cold corruption is reported on addressed lookup and never as missing history", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    {:ok, intent} = EngineWorker.new(%{"body" => String.duplicate("a", 1000)})
    {:ok, job} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)
    file = RecoveryHelpers.canonical(path, 1)
    <<prefix::binary-size(100), byte, rest::binary>> = File.read!(file)
    File.write!(file, <<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>)
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    assert {:error, error} = Tay.get_job(intent.id, name: @name)
    refute error == :not_found
    assert EngineHelpers.eventually(fn -> Tay.status(name: @name).state == :failed end)
    EngineHelpers.stop(root)
  end

  test "the preceding job-only index remains readable through full replay", %{path: path} do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    {:ok, intent} = EngineWorker.new(%{"legacy" => "kept"})
    {:ok, job} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)
    alias Tay.Storage.{DiskIndex, V2.Authority}
    {:ok, current} = Authority.decode_current(File.read!(Path.join(path, "CURRENT")))
    epoch = Path.join([path, "epochs", "e-" <> Base.encode16(current.epoch_id, case: :lower)])
    {:ok, manifest} = Authority.decode_manifest(File.read!(Path.join(epoch, "MANIFEST")))
    {:ok, index} = File.open(Path.join(epoch, "RECOVERY"), [:read, :binary])
    {:ok, root_ref} = DiskIndex.decode_root(manifest.recovery_index.root)

    {:ok, entries} =
      DiskIndex.reduce(fn at, size -> :file.pread(index, at, size) end, root_ref, [], fn id,
                                                                                         pointer,
                                                                                         acc ->
        {:ok,
         [{id, Map.drop(pointer, ["summary", "epoch", "segment_bytes", "segment_digest"])} | acc]}
      end)

    File.close(index)
    Process.put(:legacy_index_pages, [])

    {:ok, root_ref, bytes} =
      DiskIndex.build(Enum.reverse(entries), fn _at, page ->
        Process.put(:legacy_index_pages, [page | Process.get(:legacy_index_pages)])
        :ok
      end)

    File.write!(Path.join(epoch, "RECOVERY"), Enum.reverse(Process.delete(:legacy_index_pages)))
    {:ok, encoded} = DiskIndex.encode_root(root_ref)

    {:ok, manifest_bytes} =
      Authority.encode_manifest(%{manifest | recovery_index: %{root: encoded, bytes: bytes}})

    File.write!(Path.join(epoch, "MANIFEST"), manifest_bytes)

    {:ok, current_bytes} =
      Authority.encode_current(%{
        current
        | manifest_digest: Authority.manifest_digest(manifest_bytes)
      })

    File.write!(Path.join(path, "CURRENT"), current_bytes)
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    assert {:ok, restored} = Tay.get_job(intent.id, name: @name)
    assert restored.args == intent.args
    assert {:ok, migrated} = Tay.compact(name: @name, terminal_retention: :infinity)
    assert migrated.recovered.manifest.recovery_index.format == 3
    EngineHelpers.stop(root)
  end

  test "full verification authenticates the auxiliary index as well as job locations", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)

    {:ok, schedule} =
      Tay.Schedule.new(
        "indexed-schedule",
        %{
          "task" => "worker.v1",
          "args" => %{},
          "every" => %{"hours" => 1},
          "options" => %{"queue" => "default"}
        },
        1000
      )

    assert {:ok, _} = Tay.register_schedule(schedule, name: @name)
    assert {:ok, stats} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)

    {:ok, index_root} =
      Tay.Storage.DiskIndex.decode_root(stats.recovered.manifest.recovery_index.schedules)

    epoch = Path.dirname(RecoveryHelpers.segment_directory(path))
    file = Path.join(epoch, "RECOVERY")
    bytes = File.read!(file)
    offset = index_root.offset
    <<prefix::binary-size(^offset), byte, rest::binary>> = bytes
    File.write!(file, <<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>)
    {:ok, native} = RecoveryHelpers.open(path)
    assert {:error, _} = Tay.Storage.V2.Reader.recover(native, Tay.Storage.V2.Reducer.candidate())
    Tay.Storage.Native.shutdown(native)
  end
end
