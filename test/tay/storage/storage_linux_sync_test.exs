defmodule Tay.Storage.LinuxSyncTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Writer, Native}
  import Tay.Test.NativeHelpers
  @moduletag :linux_sync
  if :os.type() != {:unix, :linux} or System.get_env("TAY_TEST_SYNC") != "1" do
    @moduletag skip: "requires explicitly validated local Linux test volume and TAY_TEST_SYNC=1"
  end

  setup do
    Process.flag(:trap_exit, true)
    path = path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, opts \\ []),
    do:
      Writer.start_link(
        Keyword.merge(
          [data_dir: path, durability: :sync, validated_filesystem: true, test_helper: true],
          opts
        )
      )

  test "strict append and rotation cross every required syscall barrier", %{path: path} do
    parent = self()

    hook = fn tag, _ ->
      send(parent, {:barrier, tag})
      :ok
    end

    {:ok, w} = start(path, on_transition: hook)
    assert {:ok, %{sequence: 1, durability: :sync}} = Writer.append(w, 1, 1, "durable")
    assert_receive {:barrier, :append_written}
    assert_receive {:barrier, :append_synced}
    assert {:ok, %{id: 2}} = Writer.rotate(w)

    for tag <- [
          :r0,
          :r1,
          {:r2, :synced},
          :r2,
          {:r3, :created},
          :r3,
          {:r4, :synced},
          :r4,
          :r5,
          :r6,
          :r7
        ] do
      assert_receive {:barrier, ^tag}
    end

    assert {:ok, %{sequence: 2, durability: :sync}} = Writer.append(w, 1, 1, "next durable")
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert {:ok, [2, 1]} = Writer.reduce(w, [], fn r, _, acc -> [r.sequence | acc] end)
    GenServer.stop(w)
  end

  test "full append with failed fsync is uncertain and cannot be acknowledged", %{path: path} do
    {:ok, w} = start(path)
    :ok = Writer.inject_fault(w, :sync, 1, :error, 5)
    assert {:error, {:uncertain, %{operation: :sync}}} = Writer.append(w, 1, 1, "unacknowledged")
    assert Writer.status(w).state == :poisoned
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert Writer.status(w).next_sequence == 2
    GenServer.stop(w)
  end

  test "directory sync failure before publication readiness prohibits next append", %{path: path} do
    hook = fn
      :r5, n -> Native.fault(n, :sync_dir, 1, :error, 5)
      _, _ -> :ok
    end

    {:ok, w} = start(path, on_transition: hook)
    {:ok, _} = Writer.append(w, 1, 1, "previous sync success")
    assert {:error, {:uncertain, _}} = Writer.rotate(w)
    assert {:error, {:poisoned, _}} = Writer.append(w, 1, 1, "not accepted")
    assert File.stat!(Path.join([path, "segments", canonical(2)])).size == 44
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert {:ok, [1]} = Writer.reduce(w, [], fn r, _, acc -> [r.sequence | acc] end)
    GenServer.stop(w)
  end

  test "tmpfs is refused for strict durability even with operator assertion" do
    target = "/dev/shm/tay-phase2-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    assert {:error, %{reason: "unsupported_capability"}} = start(target)
    refute File.exists?(target)
  end

  test "sync acknowledgment survives an abrupt independent BEAM exit", %{path: path} do
    script =
      "Process.flag(:trap_exit, true); {:ok, w} = Tay.Storage.Writer.start_link(data_dir: hd(System.argv()), durability: :sync, validated_filesystem: true); {:ok, r} = Tay.Storage.Writer.append(w, 1, 1, \"synced before VM exit\"); IO.puts(r.sequence); System.halt(23)"

    assert {"1\n", 23} = child_elixir(script, [path])
    {:ok, w} = start(path)
    assert Writer.status(w).next_sequence == 2
    GenServer.stop(w)
  end
end
