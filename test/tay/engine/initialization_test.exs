defmodule Tay.Engine.InitializationTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Writer
  alias Tay.Test.NativeHelpers
  alias Tay.Test.RecoveryHelpers, as: R

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "initialization publishes an empty Store-v2 generation and refuses any initialized store",
       %{
         path: path
       } do
    assert {:ok, %{epoch_id: epoch_id, segment_id: 1, durability: :write}} =
             Tay.Storage.initialize(data_dir: path, durability: :write)

    epoch = "e-" <> Base.encode16(epoch_id, case: :lower)

    assert File.stat!(
             Path.join([path, "epochs", epoch, "segments", Path.basename(R.canonical(path, 1))])
           ).size == 44

    assert File.exists?(Path.join(path, "STORE-V2"))
    assert File.exists?(Path.join(path, "CURRENT"))
    refute File.exists?(Path.join(path, "STORE"))
    refute File.exists?(Path.join(path, "segments"))
    before = R.snapshot(path)

    assert {:error, :already_initialized} =
             R.after_release(fn -> Tay.Storage.initialize(data_dir: path, durability: :write) end)

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

    assert File.exists?(Path.join(path, "CURRENT"))
  end

  test "poison is notified before cleanup, including a live idle Writer", %{path: path} do
    R.store(path)

    spec = %{
      codec: Tay.Event,
      initial_acc: Tay.State.Transition.candidate(%{}, Tay.Event.Value.defaults()),
      reducer: &Tay.State.Transition.reduce/3,
      options: []
    }

    {:ok, writer} = R.start(path, spec, lifecycle_observer: self())
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
