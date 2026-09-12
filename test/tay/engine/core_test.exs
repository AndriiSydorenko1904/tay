defmodule Tay.Engine.CoreTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{NativeHelpers, EngineWorker}
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.EngineHelpers, as: H
  @name __MODULE__
  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "real insertion, private view, no execution, stable definition and replay", %{path: path} do
    {:ok, root} = H.start(path, @name)
    assert Tay.status(name: @name).state == :ready
    assert {:ok, intent} = EngineWorker.new(%{"x" => [nil, 3, "hello"]})
    assert {:ok, job} = Tay.insert({:ok, intent}, name: @name)
    assert job.state == :available
    assert job.attempt == 0
    assert {:ok, ^job} = Tay.get_job(job.id, name: @name)
    assert {:ok, ^job} = Tay.insert(intent, name: @name)
    assert Tay.status(name: @name).jobs == 1
    H.stop(root)
    {:ok, root} = H.restart(path, @name)
    assert {:ok, recovered} = Tay.get_job(job.id, name: @name)

    assert Map.drop(Map.from_struct(recovered), [:revision]) ==
             Map.drop(Map.from_struct(job), [:revision])

    refute recovered.revision == job.revision
    assert {:ok, ^recovered} = Tay.insert(job, name: @name)
    H.stop(root)
  end

  test "concurrent same-ID reconciliation appends exactly once; divergent definition conflicts",
       %{path: path} do
    {:ok, root} = H.start(path, @name)
    {:ok, intent} = EngineWorker.new(%{})

    results =
      Task.async_stream(1..20, fn _ -> Tay.insert(intent, name: @name) end, max_concurrency: 20)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert File.stat!(R.canonical(path, 1)).size < 1000
    before = R.snapshot(path)
    {:ok, conflict} = EngineWorker.new(%{"different" => true}, id: intent.id)
    assert {:error, %{reason: :id_conflict}} = Tay.insert(conflict, name: @name)
    assert R.snapshot(path) == before
    H.stop(root)
  end

  test "reconciliation precedes lower insertion limits and current worker mappings", %{path: path} do
    {:ok, root} = H.start(path, @name)
    {:ok, intent} = EngineWorker.new(%{"text" => String.duplicate("a", 2000)})
    assert {:ok, _} = Tay.insert(intent, name: @name)
    H.stop(root)

    {:ok, root} =
      H.restart(path, @name,
        max_insert_args_bytes: 5,
        max_insert_payload_bytes: 1,
        workers: %{},
        queues: []
      )

    before = R.snapshot(path)
    assert {:ok, %{worker: nil, queue: "default"}} = Tay.insert(intent, name: @name)
    assert Tay.status(name: @name).blocked_jobs == 1
    assert R.snapshot(path) == before
    H.stop(root)
  end

  test "new insertion budgets fail before append and do not make history invalid", %{path: path} do
    for extra <- [
          [max_jobs: 0],
          [max_state_bytes: 1],
          [max_state_nodes: 1],
          [max_insert_args_bytes: 5],
          [max_insert_payload_bytes: 1]
        ] do
      {:ok, root} = H.restart(path, @name, extra)
      before = R.snapshot(path)
      assert {:error, %{kind: :capacity}} = Tay.insert(EngineWorker.new(%{"x" => 1}), name: @name)
      assert R.snapshot(path) == before
      assert Tay.status(name: @name).state == :ready
      H.stop(root)
    end
  end

  test "missing namespace, torn tail, and semantic failure never bootstrap or publish", %{
    path: path
  } do
    missing = Path.join(path, "missing")
    assert {:error, _} = H.start(missing, @name)
    refute File.exists?(missing)

    for suffix <- [<<1>>, Tay.Test.EventHelpers.fixture("N7")] do
      File.write!(R.canonical(path, 1), R.segment(1, 1, [suffix]))
      before = R.snapshot(path)
      assert {:error, _} = H.restart(path, @name)
      assert R.snapshot(path) == before
      assert Tay.status(name: @name).state == :unavailable
      assert {:error, %{kind: :unavailable}} = Tay.get_job(Tay.JobID.new(), name: @name)
    end
  end
end
