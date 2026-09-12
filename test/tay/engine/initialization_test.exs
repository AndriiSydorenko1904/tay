defmodule Tay.Engine.InitializationTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Writer, Record}
  alias Tay.Test.{NativeHelpers, RecoveryHelpers}
  alias Tay.Test.RecoveryHelpers, as: R

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "initialization creates only empty genesis and refuses any initialized store", %{
    path: path
  } do
    assert {:ok, %{segment_id: 1, durability: :write}} =
             Tay.Storage.initialize(data_dir: path, durability: :write)

    assert File.stat!(R.canonical(path, 1)).size == 44
    before = R.snapshot(path)

    assert {:error, :already_initialized} =
             R.after_release(fn -> Tay.Storage.initialize(data_dir: path, durability: :write) end)

    assert R.snapshot(path) == before
  end

  test "existing highest sealed is never given a successor by initialize-only", %{path: path} do
    {:ok, frame} =
      Record.encode(%Record{
        record_type: 47,
        payload_schema_version: 3,
        sequence: 1,
        payload: <<1>>
      })

    R.store(path, [R.segment(1, 1, [frame], true)])
    before = R.snapshot(path)

    assert {:error, :already_initialized} =
             Tay.Storage.initialize(data_dir: path, durability: :write)

    assert R.snapshot(path) == before
  end

  test "preexisting empty root requires explicit bootstrap intent", %{path: path} do
    File.mkdir_p!(path)

    assert {:error, :explicit_bootstrap_required} =
             Tay.Storage.initialize(data_dir: path, durability: :write)

    assert {:ok, _} =
             R.after_release(fn ->
               Tay.Storage.initialize(data_dir: path, durability: :write, bootstrap: true)
             end)
  end

  test "poison is notified before cleanup, including a live idle Writer", %{path: path} do
    R.store(path)
    {:ok, writer} = R.start(path, RecoveryHelpers.spec(), lifecycle_observer: self())
    {:ok, _, _} = R.activate(writer)
    os_pid = Writer.status(writer).os_pid
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert_receive {Writer, ^writer, :poisoned}, 2000
    assert Process.alive?(writer)
    assert Writer.status(writer).state == :poisoned
    GenServer.stop(writer)
    assert_receive {Writer, ^writer, :closed}
  end
end
