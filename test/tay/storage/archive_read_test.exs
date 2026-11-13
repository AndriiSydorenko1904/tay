defmodule Tay.Storage.ArchiveReadTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Native, V2.Authority}
  alias Tay.Test.{NativeHelpers, RecoveryHelpers}

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    {:ok, current} = Authority.decode_current(File.read!(Path.join(path, "CURRENT")))
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path, epoch: current.epoch_id}
  end

  test "interrupted pruning resumes after segment-directory or epoch removal", %{path: path} do
    current = File.read!(Path.join(path, "CURRENT"))
    {:ok, selected} = Authority.decode_current(current)

    for site <- [
          :v2_reclaim_segments_unlink,
          :v2_reclaim_epoch_sync,
          :v2_reclaim_epoch_unlink,
          :v2_reclaim_epochs_sync
        ] do
      old = :crypto.strong_rand_bytes(16)
      directory = Path.join([path, "epochs", "e-" <> Base.encode16(old, case: :lower)])
      File.mkdir_p!(Path.join(directory, "segments"))
      File.write!(Path.join(directory, "RECOVERY"), "index")
      File.write!(Path.join(directory, "MANIFEST"), "metadata")
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.v2_select(native, selected.epoch_id)
      assert :ok = Native.enable_mutations(native)
      assert :ok = Native.fault(native, site, 1, :crash_after)
      assert {:error, _} = Native.v2_prune(native, old, current, false, [])
      Native.shutdown(native)
      {:ok, reopened} = RecoveryHelpers.after_release(fn -> RecoveryHelpers.open(path) end)
      assert :ok = Native.v2_select(reopened, selected.epoch_id)
      assert :ok = Native.enable_mutations(reopened)
      assert {:ok, %{complete: true}} = Native.v2_prune(reopened, old, current, false, [])
      assert File.read!(Path.join(path, "CURRENT")) == current
      refute File.exists?(directory)
      assert :ok = Native.shutdown(reopened)
    end
  end

  test "pruning is bounded, honours reader pins and rejects stale CURRENT", %{path: path} do
    old = <<1::128>>
    directory = Path.join([path, "epochs", "e-" <> Base.encode16(old, case: :lower)])
    File.mkdir_p!(Path.join(directory, "segments"))
    File.write!(Path.join(directory, "RECOVERY"), "retained-index")
    File.write!(Path.join(directory, "MANIFEST"), "metadata")

    for id <- 1..40 do
      {:ok, name} = Tay.Storage.Segment.filename(id)
      File.write!(Path.join([directory, "segments", name]), "archive")
    end

    current = File.read!(Path.join(path, "CURRENT"))
    {:ok, native} = RecoveryHelpers.open(path)
    {:ok, selected} = Authority.decode_current(current)
    assert :ok = Native.v2_select(native, selected.epoch_id)
    assert :ok = Native.enable_mutations(native)
    assert {:ok, _} = Native.open_epoch_read(native, old, :epoch, "RECOVERY")
    assert {:error, %{reason: "ebusy"}} = Native.v2_prune(native, old, current, false, [])
    assert File.exists?(directory)
    assert :ok = Native.close_read(native)
    assert {:error, _} = Native.v2_prune(native, old, <<0::608>>, false, [])
    assert length(File.ls!(Path.join(directory, "segments"))) == 40

    assert {:ok, %{complete: false, reclaimed_bytes: 224}} =
             Native.v2_prune(native, old, current, true, [1])

    assert File.exists?(Path.join(directory, "RECOVERY"))
    assert {:ok, %{complete: true}} = Native.v2_prune(native, old, current, true, [1])
    assert File.ls!(Path.join(directory, "segments")) == ["00000000000000000001.tay"]
    assert {:ok, %{complete: true}} = Native.v2_prune(native, old, current, false, [])
    refute File.exists?(directory)
    assert :ok = Native.shutdown(native)
  end

  test "inspection reads a pinned archive without changing the selected epoch", %{
    path: path,
    epoch: epoch
  } do
    {:ok, native} = RecoveryHelpers.open(path)
    {:ok, identity} = Native.open_epoch_read(native, epoch, :epoch, "MANIFEST")
    assert identity.links == 1
    assert {:ok, bytes} = Native.read(native, 0, identity.size)
    assert {:ok, %{epoch_id: ^epoch}} = Authority.decode_manifest(bytes)
    assert :ok = Native.close_read(native)
    assert :ok = Native.v2_select(native, epoch)
    assert {:ok, files} = Native.list(native, :epoch)
    assert Enum.any?(files, &(&1.name == "MANIFEST"))
    assert :ok = Native.shutdown(native)
  end

  test "renaming an archive ancestor invalidates its pinned reader", %{path: path, epoch: epoch} do
    {:ok, native} = RecoveryHelpers.open(path)
    {:ok, identity} = Native.open_epoch_read(native, epoch, :epoch, "MANIFEST")
    directory = Path.join([path, "epochs", "e-" <> Base.encode16(epoch, case: :lower)])
    File.rename!(directory, directory <> ".moved")
    assert {:error, _} = Native.read(native, 0, identity.size)
    assert {:error, _} = Native.close_read(native)
    assert :ok = Native.shutdown(native)
  end
end
