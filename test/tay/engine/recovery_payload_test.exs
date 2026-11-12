defmodule Tay.Engine.RecoveryPayloadTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: Recovery
  @name __MODULE__

  test "larger and deeper arguments survive insertion, checkpoint and recovery" do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    Recovery.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    nested = Enum.reduce(1..40, nil, fn _, value -> [value] end)

    args = %{
      "text" => String.duplicate("x", 300_000),
      "nested" => nested,
      "nodes" => List.duplicate(0, 12_000)
    }

    {:ok, root} = EngineHelpers.start(path, @name, client_slots: 4)
    {:ok, job} = EngineWorker.new(args) |> Tay.insert(name: @name)
    EngineHelpers.stop(root)

    for phase <- [:tail, :checkpoint] do
      before = Recovery.snapshot(path)

      assert {:ok, %{jobs: 1}} =
               Recovery.after_release(fn ->
                 Tay.Diagnostics.inspect(data_dir: path, durability: :write)
               end)

      assert Recovery.snapshot(path) == before
      {:ok, root} = EngineHelpers.restart(path, @name)
      assert {:ok, %{args: ^args}} = Tay.get_job(job.id, name: @name)
      if phase == :tail, do: assert({:ok, _} = Tay.compact(name: @name))
      EngineHelpers.stop(root)
    end
  end
end
