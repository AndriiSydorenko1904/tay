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
end
