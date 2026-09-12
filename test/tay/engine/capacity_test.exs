defmodule Tay.Engine.CapacityTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{NativeHelpers, EngineWorker}
  alias Tay.Test.EngineHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Storage.Segment
  @name __MODULE__
  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "terminal or invalid activation result cannot yield mutation capability" do
    assert {:error, %{reason: :coordinate_space_exhausted}} =
             Tay.Engine.activation_capability(%{state: :terminal, admission_ref: nil})

    for summary <- [
          %{state: :ready, admission_ref: nil},
          %{state: :terminal, admission_ref: make_ref()},
          %{}
        ],
        do: assert({:error, _} = Tay.Engine.activation_capability(summary))
  end

  test "sequence and segment headroom model rejects pre-I/O rather than wrapping", %{path: path} do
    {:ok, root} = H.start(path, @name)
    engine = H.engine(root)
    state = :sys.get_state(engine)
    before = R.snapshot(path)
    # Modeling unreachable-in-a-small-fixture coordinate boundaries; NOT a
    # claim to have manufactured 2^64 physically contiguous historical events.
    :sys.replace_state(engine, fn s -> %{s | next_sequence: Segment.max_id() + 1} end)

    assert {:error, %{kind: :capacity, reason: :sequence_exhausted}} =
             Tay.insert(EngineWorker.new(%{}), name: @name)

    :sys.replace_state(engine, fn _ ->
      %{
        state
        | segment: %{
            state.segment
            | id: Segment.max_id(),
              bytes: state.config.rotation_target_bytes,
              count: 1
          }
      }
    end)

    assert {:error, %{kind: :capacity, reason: :segment_id_exhausted}} =
             Tay.insert(EngineWorker.new(%{}), name: @name)

    assert R.snapshot(path) == before
    :sys.replace_state(engine, fn _ -> state end)
    H.stop(root)
  end

  @tag timeout: 180_000
  test "live insertion crosses minimum rotation target with exact receipts and full restart equivalence",
       %{path: path} do
    options = [
      rotation_target_bytes: Segment.min_rotation_bytes(),
      max_insert_payload_bytes: 2_097_152,
      max_insert_args_bytes: 2_097_152,
      client_slots: 4,
      client_bytes: 8_388_608
    ]

    {:ok, root} = H.start(path, @name, options)
    args = %{"text" => String.duplicate("x", 1_048_576)}

    jobs =
      for _ <- 1..16 do
        {:ok, job} = Tay.insert(EngineWorker.new(args), name: @name, timeout: 30_000)
        job
      end

    assert File.exists?(R.canonical(path, 2))
    H.stop(root)
    {:ok, root} = H.restart(path, @name, options)

    for job <- jobs do
      assert {:ok, actual} = Tay.get_job(job.id, name: @name)
      assert actual.definition == job.definition
      assert actual.state == :available
    end

    H.stop(root)
  end

  test "canonical numeric identity distinguishes integer and both floating zeros", %{path: path} do
    {:ok, root} = H.start(path, @name)
    <<minus_zero::float-64>> = <<0x8000000000000000::64>>
    {:ok, job} = EngineWorker.new(%{"value" => minus_zero})
    assert {:ok, _} = Tay.insert(job, name: @name)

    for value <- [0, 0.0] do
      {:ok, other} = EngineWorker.new(%{"value" => value}, id: job.id)
      assert {:error, %{reason: :id_conflict}} = Tay.insert(other, name: @name)
    end

    assert {:ok, _} = Tay.insert(job, name: @name)
    H.stop(root)
  end
end
