defmodule Tay.Engine.CompactionTest do
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

  test "manual compaction drains, adopts V1, restarts V2 and scopes revisions", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)
    {:ok, intent} = EngineWorker.new(%{"before" => "compaction"})
    assert {:ok, original} = Tay.insert(intent, name: @name)
    assert {:tay_revision, _, _, _, physical_revision} = original.revision

    assert {:ok, stats} = Tay.compact(name: @name, timeout: 60_000)
    assert stats.epoch_id == stats.recovered.epoch_id
    assert stats.reclamation == :complete
    assert stats.reclaimed_bytes > 0
    refute File.exists?(Path.join(path, "ADOPTION"))
    assert Tay.status(name: @name).state == :ready
    assert {:ok, rewritten} = Tay.get_job(original.id, name: @name)
    assert {:tay_revision_v2, _, epoch_id, _, _, logical_revision} = rewritten.revision
    assert epoch_id == stats.epoch_id
    assert logical_revision == 1
    assert physical_revision == 1

    assert {:error, %{kind: :conflict}} =
             Tay.cancel(original.id, name: @name, expected_revision: original.revision)

    {:ok, after_intent} = EngineWorker.new(%{"after" => "compaction"})
    assert {:ok, after_job} = Tay.insert(after_intent, name: @name)
    assert {:tay_revision_v2, _, ^epoch_id, _, _, 1} = after_job.revision

    assert {:ok, second} = Tay.compact(name: @name, timeout: 60_000)
    assert second.epoch_id != epoch_id
    assert second.previous_epoch_id == epoch_id
    assert second.reclamation == :complete
    assert second.reclaimed_bytes > 0
    refute File.exists?(Path.join([path, "epochs", "e-" <> Base.encode16(epoch_id, case: :lower)]))
    assert {:ok, after_rewrite} = Tay.get_job(after_job.id, name: @name)
    assert {:tay_revision_v2, _, second_id, _, _, 1} = after_rewrite.revision
    assert second_id == second.epoch_id
    EngineHelpers.stop(root)

    {:ok, restarted} = EngineHelpers.restart(path, @name)

    assert {:ok, %{revision: {:tay_revision_v2, _, ^second_id, _, _, 1}}} =
             Tay.get_job(after_job.id, name: @name)

    EngineHelpers.stop(restarted)
  end

  test "lost CURRENT reply reconciles by the validated new pointer", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name, storage_timeout: 300)
    writer = :sys.get_state(@name).writer
    assert :ok = Tay.Storage.Writer.inject_fault(writer, :v2_publish_current, 1, :drop_reply)

    assert {:ok, stats} = Tay.compact(name: @name, timeout: 60_000)
    assert stats.publication_reconciled
    assert Tay.status(name: @name).state == :ready
    assert {:ok, second} = Tay.compact(name: @name, timeout: 60_000)
    assert second.previous_epoch_id == stats.epoch_id
    EngineHelpers.stop(root)
  end

  test "reclamation failure never rolls back CURRENT and startup resumes cleanup", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)
    writer = :sys.get_state(@name).writer
    assert :ok = Tay.Storage.Writer.inject_fault(writer, :v2_reclaim, 1, :error)

    assert {:ok, stats} = Tay.compact(name: @name, timeout: 60_000)
    assert stats.reclamation == :deferred
    assert stats.reclaimed_bytes == 0
    assert Tay.status(name: @name).state == :ready
    refute File.exists?(Path.join(path, "ADOPTION"))

    {:ok, intent} = EngineWorker.new(%{"after_cleanup" => true})
    assert {:ok, %{revision: {:tay_revision_v2, _, _, _, _, 1}}} =
             Tay.insert(intent, name: @name)

    EngineHelpers.stop(root)
  end
end
