defmodule Tay.Storage.CheckpointIndexTest do
  use ExUnit.Case, async: false
  alias Tay.Storage.{DiskIndex, Native, Record, V2.CheckpointIndex, V2.Reader, V2.Reducer}
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers, RecoveryHelpers}
  @name __MODULE__

  test "persistent checkpoint roots retain archive bodies across epochs without copying them" do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, root} = EngineHelpers.restart(path, @name, compaction: false)
    {:ok, intent} = EngineWorker.new(%{"data" => String.duplicate("x", 200_000)})
    {:ok, job} = Tay.insert(intent, name: @name)
    {:ok, _} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    EngineHelpers.stop(root)
    {:ok, native} = RecoveryHelpers.open(path)
    {:ok, recovered} = Reader.recover(native, Reducer.candidate())
    :ok = Native.enable_mutations(native)
    <<_header::binary-size(44), records::binary>> = File.read!(RecoveryHelpers.canonical(path, 1))
    {:ok, record, _} = Record.decode(records)
    [{id, original}] = Map.to_list(recovered.candidate.jobs)
    pointer = CheckpointIndex.pointer(recovered.epoch_id, 1, 44, record, original)
    epoch = :crypto.strong_rand_bytes(16)
    :ok = Native.v2_begin(native, :crypto.strong_rand_bytes(16))
    {:ok, transaction} = CheckpointIndex.begin(native, epoch)
    {:ok, transaction} = CheckpointIndex.put_job(transaction, id, pointer, original)
    {:ok, descriptor} = CheckpointIndex.finish(transaction)
    assert CheckpointIndex.valid?(descriptor)
    assert CheckpointIndex.count(descriptor) == 1
    assert CheckpointIndex.count(descriptor, :work) == 0
    assert :ok = CheckpointIndex.verify_roots(native, descriptor, epoch, :candidate)
    assert {:ok, fetched} = CheckpointIndex.fetch(native, descriptor, epoch, id, :candidate)
    assert fetched.definition == original.definition
    assert {:ok, objects} = CheckpointIndex.objects(descriptor)
    assert DiskIndex.object(recovered.epoch_id, 1, 1) in objects
    assert DiskIndex.object(epoch, 0, 0) in objects
    assert :ok = Native.v2_publish_epoch(native, epoch)
    assert :ok = Native.v2_abort(native)

    next_epoch = :crypto.strong_rand_bytes(16)
    :ok = Native.v2_begin(native, :crypto.strong_rand_bytes(16))
    {:ok, transaction} = CheckpointIndex.begin(native, next_epoch, descriptor)
    {:ok, transaction} = CheckpointIndex.repack(transaction, 0)
    {:ok, compacted} = CheckpointIndex.finish(transaction)
    assert {:ok, objects} = CheckpointIndex.objects(compacted)
    refute DiskIndex.object(epoch, 0, 0) in objects
    assert {:ok, fetched} = CheckpointIndex.fetch(native, compacted, next_epoch, id, :candidate)
    assert fetched.definition == original.definition
    assert :ok = Native.v2_publish_epoch(native, next_epoch)
    assert :ok = Native.v2_abort(native)
    # Once no root references the old metadata file, its removal cannot break
    # the newly published index. The shared snapshot segment remains untouched.
    index_path =
      Path.join([path, "epochs", "e-" <> Base.encode16(epoch, case: :lower), "RECOVERY"])

    File.rm!(index_path)
    assert {:ok, fetched} = CheckpointIndex.fetch(native, compacted, next_epoch, id)
    assert fetched.definition == original.definition

    third_epoch = :crypto.strong_rand_bytes(16)
    :ok = Native.v2_begin(native, :crypto.strong_rand_bytes(16))
    {:ok, transaction} = CheckpointIndex.begin(native, third_epoch, compacted)
    {:ok, transaction} = CheckpointIndex.delete_job(transaction, id, pointer)
    {:ok, empty} = CheckpointIndex.finish(transaction)
    assert CheckpointIndex.count(empty) == 0
    assert :not_found = CheckpointIndex.fetch(native, empty, third_epoch, id, :candidate)
    assert {:ok, old} = CheckpointIndex.fetch(native, compacted, next_epoch, id)
    assert old.definition == original.definition
    assert :ok = Native.shutdown(native)
  end
end
