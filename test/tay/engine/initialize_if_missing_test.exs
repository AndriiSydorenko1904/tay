defmodule Tay.Engine.InitializeIfMissingTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Storage.Native
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "default startup remains existing-only", %{path: path} do
    assert {:error, _} = EngineHelpers.start(path, @name)
    refute File.exists?(path)
  end

  test "if_missing initializes a new store and restart preserves history", %{path: path} do
    assert {:ok, root} = EngineHelpers.start(path, @name, initialize: :if_missing)
    assert Tay.status(name: @name).state == :ready
    assert {:ok, job} = Tay.insert(EngineWorker.new(%{"created" => true}), name: @name)
    store = File.read!(Path.join(path, "STORE"))
    EngineHelpers.stop(root)

    assert {:ok, root} = EngineHelpers.restart(path, @name, initialize: :if_missing)
    assert File.read!(Path.join(path, "STORE")) == store
    assert {:ok, recovered} = Tay.get_job(job.id, name: @name)
    assert recovered.id == job.id
    EngineHelpers.stop(root)
  end

  test "if_missing leaves an existing valid store unchanged", %{path: path} do
    R.store(path)
    before = R.snapshot(path)
    assert {:ok, root} = EngineHelpers.start(path, @name, initialize: :if_missing)
    assert R.snapshot(path) == before
    EngineHelpers.stop(root)
  end

  test "if_missing does not bootstrap a pre-existing empty root", %{path: path} do
    File.mkdir!(path)
    before = R.snapshot(path)
    assert {:error, _} = EngineHelpers.start(path, @name, initialize: :if_missing)
    assert R.snapshot(path) == before
    refute File.exists?(Path.join(path, ".tay-owner.lock"))
  end

  test "if_missing preserves corrupt and torn existing stores", %{path: path} do
    for corruption <- [:marker, :tail] do
      File.rm_rf!(path)
      R.store(path)

      case corruption do
        :marker -> File.write!(Path.join(path, "STORE"), <<0, 1, 2>>)
        :tail -> File.write!(R.canonical(path, 1), <<1>>, [:append])
      end

      before = R.snapshot(path)
      assert {:error, _} = EngineHelpers.start(path, @name, initialize: :if_missing)
      assert R.snapshot(path) == before
    end
  end

  test "if_missing fails closed while another owner holds the store", %{path: path} do
    R.store(path)
    before = R.snapshot(path)
    assert {:ok, native} = R.open(path)
    assert {:error, _} = EngineHelpers.start(path, @name, initialize: :if_missing)
    assert R.snapshot(path) == before
    assert :ok = Native.shutdown(native)
  end
end
