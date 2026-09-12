defmodule Tay.Storage.NativeTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Native
  import Tay.Test.NativeHelpers
  import Tay.Test.SegmentHelpers, only: [header: 0]

  setup do
    path = path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "exclusive stage, positional bytes, sync, close, publication and bounded reads", %{
    path: path
  } do
    assert {:ok, native} = native(path)
    assert native.facts.created
    assert :ok = Native.mkdir_segments(native)
    assert :ok = Native.sync_dir(native, :root)
    stage = stage()
    assert {:ok, identity} = Native.create_stage(native, :segments, stage)
    assert {:ok, %{written: 44}} = Native.write(native, 0, header())
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert {:ok, %{writable: 0}} = Native.info(native)
    assert :ok = Native.publish(native, :segments, stage, canonical(1), identity)
    assert :ok = Native.sync_dir(native, :segments)
    assert {:ok, %{size: 44}} = Native.open_read(native, :segments, canonical(1))
    assert {:ok, header()} == Native.read(native, 0, 44)
    assert :ok = Native.close_read(native)
    assert :ok = Native.check(native)
    Native.close(native)
  end

  test "production helper has no fault command", %{path: path} do
    assert {:ok, n} = native(path, test_helper: false)
    assert {:error, %{reason: "invalid_protocol"}} = Native.fault(n, :write, 1, :error)
    Native.close(n)
  end

  test "startup republishes every existing ancestor entry after a possible interrupted bootstrap",
       %{path: path} do
    target = Path.join([path, "previously-created", "store"])
    File.mkdir_p!(target)
    assert {:ok, n} = native(target)
    assert {:ok, %{ancestor_syncs: count}} = Native.info(n)
    assert count == length(Path.split(target)) - 1
    assert :ok = Native.shutdown(n)
  end

  test "strict mode rejects unvalidated platform before bootstrap", %{path: path} do
    assert {:error, %{reason: "unsupported_capability"}} = native(path, durability: :sync)
    refute File.exists?(path)

    if :os.type() == {:unix, :darwin} do
      assert {:error, %{reason: "unsupported_capability"}} =
               native(path, durability: :sync, validated_filesystem: true)

      refute File.exists?(path)
    end
  end

  test "no replacing rename even when a destination appears after validation", %{path: path} do
    assert {:ok, n} = native(path)
    :ok = Native.mkdir_segments(n)
    source = stage()
    {:ok, identity} = Native.create_stage(n, :segments, source)
    {:ok, _} = Native.write(n, 0, header())
    :ok = Native.sync(n)
    :ok = Native.close_write(n)
    target = Path.join([path, "segments", canonical(1)])
    File.write!(target, "do not replace")

    assert {:error, %{reason: "eexist"}} =
             Native.publish(n, :segments, source, canonical(1), identity)

    assert File.read!(target) == "do not replace"
    assert File.read!(Path.join([path, "segments", source])) == header()
    Native.close(n)
  end

  test "staging cannot hold a record or a second writable descriptor", %{path: path} do
    assert {:ok, n} = native(path)
    :ok = Native.mkdir_segments(n)
    {:ok, _} = Native.create_stage(n, :segments, stage())
    assert {:error, %{reason: "einval"}} = Native.write(n, 0, Tay.Test.RecordHelpers.frame())
    assert {:error, %{reason: "poisoned"}} = Native.create_stage(n, :segments, stage(2))
    Native.close(n)
  end

  test "short write reports exact bytes and never retries", %{path: path} do
    assert {:ok, n} = native(path)
    :ok = Native.mkdir_segments(n)
    source = stage()
    {:ok, _} = Native.create_stage(n, :segments, source)
    :ok = Native.fault(n, :write, 1, :short, 28, 11)
    assert {:error, %{bytes_written: 11}} = Native.write(n, 0, header())
    assert File.stat!(Path.join([path, "segments", source])).size == 11
    assert {:error, %{reason: "poisoned"}} = Native.write(n, 11, "anything")
    Native.close(n)
  end

  test "a missing reply is uncertain even after the complete mutation", %{path: path} do
    assert {:ok, n} = native(path)
    n = %{n | timeout: 100}
    :ok = Native.mkdir_segments(n)
    source = stage()
    {:ok, _} = Native.create_stage(n, :segments, source)
    :ok = Native.fault(n, :write, 1, :drop_reply)
    assert {:error, %{kind: :uncertain}} = Native.write(n, 0, header())
    assert File.read!(Path.join([path, "segments", source])) == header()
    assert {:error, %{kind: :uncertain}} = Native.sync(n)
  end

  test "symlink paths are not followed", %{path: path} do
    File.mkdir!(path)
    File.ln_s!(path, path <> "-alias")
    on_exit(fn -> File.rm!(path <> "-alias") end)
    assert {:error, _} = native(path <> "-alias")
    refute File.exists?(Path.join(path, ".tay-owner.lock"))
  end

  test "a mismatched reply ID never acknowledges completed bytes", %{path: path} do
    {:ok, n} = native(path)
    :ok = Native.mkdir_segments(n)
    source = stage()
    {:ok, _} = Native.create_stage(n, :segments, source)
    :ok = Native.fault(n, :write, 1, :invalid_reply)
    assert {:error, %{kind: :uncertain, reason: :invalid_reply}} = Native.write(n, 0, header())
    assert File.read!(Path.join([path, "segments", source])) == header()
  end

  test "lost lock descriptor forbids every later mutation", %{path: path} do
    {:ok, n} = native(path)
    :ok = Native.fault(n, :check, 1, :lose_lock)
    assert {:error, %{reason: "ebadf"}} = Native.check(n)
    assert {:error, %{reason: "poisoned"}} = Native.mkdir_segments(n)
    refute File.exists?(Path.join(path, "segments"))
    Native.shutdown(n)
  end

  test "a failed pwrite syscall reports unknown bytes instead of claiming zero", %{path: path} do
    {:ok, n} = native(path)
    :ok = Native.mkdir_segments(n)
    {:ok, _} = Native.create_stage(n, :segments, stage())
    :ok = Native.fault(n, :write, 1, :syscall_error, 5)
    assert {:error, %{reason: "eio", bytes_written: :unknown}} = Native.write(n, 0, header())
    Native.shutdown(n)
  end
end
