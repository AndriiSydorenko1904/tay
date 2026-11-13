defmodule Tay.Engine.GroupCommitWriteTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: Recovery
  @name __MODULE__

  test "write durability does not enter automatic sync batching" do
    path = NativeHelpers.path()
    Recovery.store(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, root} =
      EngineHelpers.start(path, @name, durability: :write)

    {:ok, intent} = EngineWorker.new(%{})
    started = System.monotonic_time(:millisecond)
    assert {:ok, _} = Tay.insert(intent, name: @name, timeout: 500)
    assert System.monotonic_time(:millisecond) - started < 500
    EngineHelpers.stop(root)
  end
end
