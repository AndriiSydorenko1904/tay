defmodule Tay.Execution.ResourceTest do
  use ExUnit.Case, async: false
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.NativeHelpers
  alias Tay.Storage.Segment
  @name __MODULE__
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    path = NativeHelpers.path()
    H.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "active settlement coordinates cannot be consumed by another insertion", %{path: path} do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    engine = H.engine(root)
    original = :sys.get_state(engine)
    assert original.settlement_reserve == 1
    before = R.snapshot(path)
    {other, _} = H.job()

    # Coordinate-bound arithmetic model, not fabricated 2^64 record history.
    :sys.replace_state(engine, &%{&1 | next_sequence: Segment.max_id()})

    assert {:error, %{kind: :capacity, reason: :sequence_exhausted}} =
             Tay.insert(other, name: @name)

    assert {:ok, %{state: :executing}} = Tay.insert(job, name: @name)
    assert R.snapshot(path) == before

    :sys.replace_state(engine, fn s ->
      %{
        s
        | next_sequence: original.next_sequence,
          segment: %{
            s.segment
            | id: Segment.max_id(),
              bytes: Segment.rotation_bytes(),
              count: 1
          }
      }
    end)

    assert {:error, %{kind: :capacity, reason: :segment_id_exhausted}} =
             Tay.insert(other, name: @name)

    assert R.snapshot(path) == before

    :sys.replace_state(
      engine,
      &%{&1 | next_sequence: original.next_sequence, segment: original.segment}
    )

    send(task, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    assert H.eventually(fn -> Tay.status(name: @name).unsettled_executions == 0 end)
    H.stop(root)
  end

  test "a start is refused before task creation unless its finish coordinate is reserved", %{
    path: path
  } do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    engine = H.engine(root)
    queue = :sys.get_state(engine).controls[{:queue, "default"}]
    :ok = :sys.suspend(queue)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    original = :sys.get_state(engine)
    before = R.snapshot(path)
    :sys.replace_state(engine, &%{&1 | next_sequence: Segment.max_id()})
    :ok = :sys.resume(queue)
    H.wake(root)
    refute_receive {:tay_test_entered, ^token, _, _}, 40
    assert :sys.get_state(engine).running == %{}
    assert R.snapshot(path) == before
    :sys.replace_state(engine, &%{&1 | next_sequence: original.next_sequence})
    H.wake(root)
    {task, _} = H.await_entry(token)
    send(task, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    H.stop(root)
  end

  test "execution config validates queues and runtime controls" do
    base = [
      data_dir: "tmp/execution-config-unused",
      durability: :write,
      queues: [default: 2, other: 3]
    ]

    assert {:ok, config} = Tay.Engine.Config.new(base)
    assert config.queue_limits == %{"default" => 2, "other" => 3}

    assert config.execution
    assert config.clock == Tay.Execution.Clock

    for opts <- [
          [execution: false],
          [test_execution: nil],
          [test_clock: "never-an-atom"],
          [test_terminate: :not_a_function]
        ] do
      assert {:error, _} = Tay.Engine.Config.new(Keyword.merge(base, opts))
    end
  end
end
