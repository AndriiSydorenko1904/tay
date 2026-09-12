defmodule Tay.Engine.OperationalCapacityTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EventHelpers, NativeHelpers, EngineWorker}
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.EngineHelpers, as: H
  @name __MODULE__
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, options \\ []) do
    assert {:ok, root} = H.restart(path, @name, options)
    Process.unlink(root)
    on_exit(fn -> H.stop(root) end)
    root
  end

  test "recovery accounts for a newly activated successor and never double charges it", %{
    path: path
  } do
    sealed = R.segment(1, 1, [EventHelpers.fixture("E1")], true)
    R.store(path, [sealed])
    root = start(path)
    status = Tay.status(name: @name)
    assert status.segment_count == 2
    assert status.canonical_history_bytes == byte_size(sealed) + 44
    assert status.retained_definition_bytes > 0
    H.stop(root)
    root = start(path)
    again = Tay.status(name: @name)
    assert again.segment_count == status.segment_count
    assert again.canonical_history_bytes == status.canonical_history_bytes
    assert again.retained_definition_bytes == status.retained_definition_bytes
    H.stop(root)
  end

  test "lower live caps do not invalidate history or same-ID reconciliation", %{path: path} do
    R.store(path)
    root = start(path)
    assert {:ok, intent} = EngineWorker.new(%{"retained" => "definition"})
    assert {:ok, _} = Tay.insert(intent, name: @name)
    H.stop(root)
    evidence = R.snapshot(path)
    root = start(path, max_history_bytes: 0, max_segments: 0)
    assert {:ok, %{id: id}} = Tay.insert(intent, name: @name)
    assert id == intent.id

    assert {:error, %Tay.Error{kind: :capacity, reason: :max_history_bytes}} =
             Tay.insert(EngineWorker.new(%{}), name: @name)

    assert R.snapshot(path) == evidence
    H.stop(root)
    root = start(path, max_history_bytes: 10_000, max_segments: 10)
    assert {:ok, _} = Tay.insert(EngineWorker.new(%{}), name: @name)
    H.stop(root)
  end

  test "operational caps never become Event or physical validity limits" do
    base = [data_dir: "unused-operational-capacity", durability: :write]
    assert {:ok, defaults} = Tay.Engine.Config.new(base)

    for options <- [
          [max_history_bytes: 0],
          [max_segments: 0],
          [max_segments: 100],
          [start_paused: true]
        ] do
      assert {:ok, config} = Tay.Engine.Config.new(base ++ options)
      assert config.recovery == defaults.recovery
      assert config.value_limits == defaults.value_limits
      assert config.candidate_limits == defaults.candidate_limits
    end

    for options <- [
          [max_history_bytes: -1],
          [max_segments: 1.0],
          [max_segments: nil],
          [start_paused: [:default]]
        ] do
      assert {:error, _} = Tay.Engine.Config.new(base ++ options)
    end
  end
end
