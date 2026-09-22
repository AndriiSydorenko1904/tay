defmodule Tay.Storage.NativeProtocolTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Native
  import Tay.Test.NativeHelpers

  setup do
    path = path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "malformed control packet is rejected before a directory mutation", %{path: path} do
    {:ok, n} = native(path)
    port = n.port
    # MKDIR has no body. A trailing byte must not create segments/.
    Port.command(port, <<1, 3, 123::64, 99>>)
    assert_receive {^port, {:data, <<1, 3, 123::64, 1, _errno::32, 0::64, "invalid_protocol">>}}
    refute File.exists?(Path.join(path, "segments"))
    Native.shutdown(n)
  end

  test "unknown durability never silently selects write mode", %{path: path} do
    assert {:error, %{kind: :native_argument}} = Native.open(path, durability: :flush)
    assert {:error, %{kind: :native_argument}} = Native.open(path, validated_filesystem: :yes)
    assert {:error, %{kind: :native_argument}} = Native.open(path, timeout: nil)
    refute File.exists?(path)
  end

  test "other BEAM processes cannot command or close an owned Port", %{path: path} do
    {:ok, n} = native(path)
    task = Task.async(fn -> {Native.check(n), Native.close(n)} end)
    assert {{:error, %{kind: :native_owner}}, {:error, %{kind: :native_owner}}} = Task.await(task)
    assert :ok = Native.check(n)
    assert :ok = Native.shutdown(n)
  end

  test "truncated and arbitrary protocol bodies fail without creating files" do
    Process.flag(:trap_exit, true)

    for bytes <- [<<2, 1, 1::64>>, <<1, 1, 1::64, 0, 0, 100::16>>, <<1, 255, 1::64>>] do
      port =
        Port.open(
          {:spawn_executable,
           String.to_charlist(Application.app_dir(:tay, "priv/tay_storage_helper"))},
          [:binary, :exit_status, :use_stdio, {:packet, 4}]
        )

      Port.command(port, bytes)
      assert_receive {^port, {:data, <<1, _, 1::64, 1, _::32, 0::64, "invalid_protocol">>}}, 5_000
      Port.close(port)
    end
  end

  test "existing-only acquisition has no creation fallback or deferred sync", %{path: path} do
    alias Tay.Test.RecoveryHelpers, as: R
    assert {:error, %{reason: "enoent"}} = R.open(path)
    refute File.exists?(path)
    R.store(path)
    before = R.snapshot(path)
    {:ok, native} = R.open(path)
    assert Native.inspection?(native)
    assert {:ok, %{ancestor_syncs: 0, readable: false, writable: 0}} = Native.info(native)
    assert R.snapshot(path) == before
    assert :ok = Native.enable_mutations(native)
    refute Native.inspection?(native)
    assert {:ok, %{ancestor_syncs: count, writable: 0}} = Native.info(native)
    assert count > 0
    assert R.snapshot(path) == before
    Native.shutdown(native)
  end

  test "if-missing acquisition mutates only a root it creates", %{path: path} do
    assert {:ok, native} =
             Native.open_if_missing(path, durability: :write, test_helper: true)

    assert native.facts.created
    refute Native.inspection?(native)
    assert :ok = Native.shutdown(native)

    before = Tay.Test.RecoveryHelpers.snapshot(path)

    assert {:ok, native} =
             Native.open_if_missing(path, durability: :write, test_helper: true)

    refute native.facts.created
    assert Native.inspection?(native)
    assert {:ok, %{ancestor_syncs: 0}} = Native.info(native)
    assert :ok = Native.shutdown(native)
    assert Tay.Test.RecoveryHelpers.snapshot(path) == before

    empty = path <> "-existing"
    File.mkdir!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)
    assert {:error, %{reason: "enoent"}} = Native.open_if_missing(empty, durability: :write)
    refute File.exists?(Path.join(empty, ".tay-owner.lock"))
  end

  test "every mutating opcode is denied by an inspection-only helper", %{path: path} do
    alias Tay.Test.RecoveryHelpers, as: R
    R.store(path)
    before = R.snapshot(path)

    for operation <- [
          fn n -> Native.mkdir_segments(n) end,
          fn n -> Native.create_stage(n, :segments, stage()) end,
          fn n ->
            Native.create_stage(n, :root, ".tay-store-" <> String.duplicate("0", 32) <> ".tmp")
          end,
          fn n -> Native.open_active(n, canonical(1), %{size: 44, device: 1, inode: 1}) end,
          fn n -> Native.write(n, 44, <<1>>) end,
          fn n -> Native.sync(n) end,
          fn n -> Native.sync_read(n) end,
          fn n -> Native.sync_dir(n, :root) end,
          fn n -> Native.sync_dir(n, :segments) end,
          fn n -> Native.close_write(n) end,
          fn n -> Native.publish(n, :segments, stage(), canonical(2), %{device: 1, inode: 1}) end
        ] do
      {:ok, native} = R.open(path)
      assert {:error, %{reason: "eperm"}} = operation.(native)
      Native.shutdown(native)
      assert R.snapshot(path) == before
    end
  end

  test "inspection rejects a second acquisition and promotion with an open read FD", %{path: path} do
    alias Tay.Test.RecoveryHelpers, as: R
    R.store(path)
    before = R.snapshot(path)
    {:ok, native} = R.open(path)
    {:ok, _} = Native.open_read(native, :segments, canonical(1))
    assert {:error, %{reason: "ebusy"}} = Native.enable_mutations(native)
    assert {:error, %{kind: :uncertain}} = Native.info(native)
    {:ok, native} = R.after_release(fn -> R.open(path) end)
    port = native.port
    target = path <> "-must-not-exist"
    Port.command(port, <<1, 1, 456::64, 0, 0, byte_size(target)::16, target::binary>>)
    assert_receive {^port, {:data, <<1, 1, 456::64, 1, _::32, 0::64, "poisoned">>}}, 5_000
    refute File.exists?(target)
    Native.shutdown(native)
    assert R.snapshot(path) == before
  end

  test "malformed inspection/promotion packets cannot mutate namespace", %{path: path} do
    alias Tay.Test.RecoveryHelpers, as: R
    R.store(path)
    before = R.snapshot(path)

    for body <- [
          <<>>,
          <<0, 0, 100_000::32>>,
          <<0, 0, 0::32, byte_size(path)::16, path::binary>>,
          <<0, 0, 100_000::32, byte_size(path)::16, path::binary, 99>>
        ] do
      port =
        Port.open(
          {:spawn_executable,
           String.to_charlist(Application.app_dir(:tay, "priv/tay_storage_helper"))},
          [:binary, :exit_status, :use_stdio, {:packet, 4}]
        )

      Port.command(port, <<1, 18, 999::64, body::binary>>)
      assert_receive {^port, {:data, <<1, 18, 999::64, 1, _::32, 0::64, _::binary>>}}, 5_000
      Port.close(port)
      assert R.snapshot(path) == before
    end

    {:ok, native} = R.open(path)
    port = native.port
    Port.command(port, <<1, 19, 999::64, 1>>)

    assert_receive {^port, {:data, <<1, 19, 999::64, 1, _::32, 0::64, "invalid_protocol">>}},
                   5_000

    Native.shutdown(native)
    assert R.snapshot(path) == before
  end

  test "native listing entry cap returns no partial inventory", %{path: path} do
    alias Tay.Test.RecoveryHelpers, as: R
    R.store(path)
    {:ok, native} = R.open(path, max_directory_entries: 2)
    assert {:error, %{reason: "resource_limit"}} = Native.list(native, :root)
    Native.shutdown(native)
    {:ok, native} = R.open(path, max_directory_entries: 3)
    assert {:ok, entries} = Native.list(native, :root)
    assert length(entries) == 3
    Native.shutdown(native)
  end

  test "old-helper opcode rejection never falls back to creating acquisition", %{path: path} do
    # Simulate an old helper's exact EPROTO response to opcode 18 before any
    # acquisition. Fault-control installation itself performs no filesystem I/O.
    errno = if :os.type() == {:unix, :darwin}, do: 100, else: 71
    hook = fn native -> Native.fault(native, :acquire_existing, 1, :error, errno) end

    assert {:error, %{operation: :acquire_existing, reason: "invalid_protocol"}} =
             Native.open_existing(path,
               durability: :write,
               test_helper: true,
               test_before_acquire: hook
             )

    refute File.exists?(path)

    hook = fn native -> Native.fault(native, :acquire_if_missing, 1, :error, errno) end

    assert {:error, %{operation: :acquire_if_missing, reason: "invalid_protocol"}} =
             Native.open_if_missing(path,
               durability: :write,
               test_helper: true,
               test_before_acquire: hook
             )

    refute File.exists?(path)
  end
end
