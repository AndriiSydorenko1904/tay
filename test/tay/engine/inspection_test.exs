defmodule Tay.Engine.InspectionTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "empty snapshots and unavailable engine", %{path: path} do
    assert {:error, %Tay.Error{kind: :unavailable}} = Tay.jobs(name: @name)
    assert {:error, %Tay.Error{kind: :unavailable}} = Tay.stats(name: @name)
    assert {:error, %Tay.Error{kind: :unavailable}} = Tay.queues(name: @name)

    {:ok, root} = EngineHelpers.start(path, @name)

    assert {:ok, %{jobs: [], next_cursor: nil}} = Tay.jobs(name: @name)

    assert {:ok,
            %{
              available: 0,
              scheduled: 0,
              executing: 0,
              retryable: 0,
              completed: 0,
              cancelled: 0,
              discarded: 0
            }} = Tay.stats(name: @name)

    assert {:ok,
            [
              %Tay.Queue{
                key: "default",
                name: :default,
                paused: false,
                concurrency: 10,
                executing: 0,
                jobs: 0
              }
            ]} = Tay.queues(name: @name)

    EngineHelpers.stop(root)
  end

  test "filters public views and reports incrementally maintained counts", %{path: path} do
    {:ok, root} =
      EngineHelpers.start(path, @name, queues: [default: 2, mail: 1], start_paused: true)

    {:ok, first} = EngineWorker.new(%{"n" => 1}) |> Tay.insert(name: @name)

    {:ok, second_intent} =
      EngineWorker.new(%{"n" => 2}, queue: :mail, scheduled_at: 4_000_000_000_000)

    {:ok, second} = Tay.insert(second_intent, name: @name)
    {:ok, cancelled} = Tay.cancel(first.id, name: @name)

    assert {:ok, %{jobs: [^cancelled], next_cursor: nil}} =
             Tay.jobs(name: @name, state: :cancelled)

    assert {:ok, %{jobs: [^second], next_cursor: nil}} =
             Tay.jobs(name: @name, queues: [:mail], workers: [EngineWorker])

    assert {:ok, %{jobs: partial_jobs, next_cursor: nil}} =
             Tay.jobs(name: @name, worker_contains: "worker.")

    assert MapSet.new(Enum.map(partial_jobs, & &1.id)) == MapSet.new([second.id, cancelled.id])

    assert {:ok, %{jobs: [], next_cursor: nil}} =
             Tay.jobs(name: @name, worker_contains: "missing")

    assert {:ok, %{jobs: [^cancelled], next_cursor: nil}} =
             Tay.jobs(name: @name, id: cancelled.id)

    assert {:ok, %{cancelled: 1, scheduled: 1, available: 0}} = Tay.stats(name: @name)

    assert {:ok, queues} = Tay.queues(name: @name)

    assert %{paused: true, jobs: 1, states: %{cancelled: 1}} =
             Enum.find(queues, &(&1.key == "default"))

    assert %{paused: true, jobs: 1, states: %{scheduled: 1}} =
             Enum.find(queues, &(&1.key == "mail"))

    EngineHelpers.stop(root)
  end

  test "cursor pagination is deterministic, bounded, and tied to filters", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)

    inserted =
      for n <- 1..125 do
        {:ok, job} = EngineWorker.new(%{"n" => n}) |> Tay.insert(name: @name)
        job
      end

    {seen, cursor} = collect([], nil, @name)
    assert cursor == nil
    assert length(seen) == 125
    assert Enum.uniq(Enum.map(seen, & &1.id)) == Enum.map(seen, & &1.id)
    assert MapSet.new(Enum.map(seen, & &1.id)) == MapSet.new(Enum.map(inserted, & &1.id))

    {:ok, first} = Tay.jobs(name: @name, limit: 50)
    assert first.total_count == 125
    assert first.previous_cursor == nil
    assert is_binary(first.next_cursor)
    assert is_binary(first.last_cursor)

    {:ok, last} = Tay.jobs(name: @name, limit: 50, cursor: first.last_cursor)
    assert length(last.jobs) == 25
    assert last.total_count == 125
    assert last.next_cursor == nil
    assert last.last_cursor == nil
    assert is_binary(last.previous_cursor)

    {:ok, middle} = Tay.jobs(name: @name, limit: 50, cursor: last.previous_cursor)
    assert length(middle.jobs) == 50
    assert is_binary(middle.previous_cursor)
    assert is_binary(middle.next_cursor)

    {:ok, back_to_first} = Tay.jobs(name: @name, limit: 50, cursor: middle.previous_cursor)
    assert Enum.map(back_to_first.jobs, & &1.id) == Enum.map(first.jobs, & &1.id)
    assert back_to_first.previous_cursor == nil

    {:ok, %{next_cursor: cursor}} = Tay.jobs(name: @name, limit: 3)
    assert is_binary(cursor)

    assert {:error, %Tay.Error{kind: :invalid}} =
             Tay.jobs(name: @name, limit: 3, state: :available, cursor: cursor)

    for options <- [
          [limit: 0],
          [limit: 101],
          [cursor: "bad"],
          [states: []],
          [state: :unknown],
          [state: :available, states: [:available]],
          [queues: ["default", "default"]],
          [worker: "engine.worker.v1", worker_contains: "engine"]
        ] do
      assert {:error, %Tay.Error{kind: :invalid}} = Tay.jobs([name: @name] ++ options)
    end

    EngineHelpers.stop(root)
  end

  test "recovery reconstructs inspection state", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)
    {:ok, job} = EngineWorker.new(%{"recover" => true}) |> Tay.insert(name: @name)
    {:ok, cancelled} = Tay.cancel(job.id, name: @name)
    EngineHelpers.stop(root)

    {:ok, root} = EngineHelpers.restart(path, @name)
    assert {:ok, %{jobs: [recovered]}} = Tay.jobs(name: @name, state: :cancelled)
    assert recovered.id == cancelled.id
    assert recovered.state == :cancelled
    assert {:ok, %{cancelled: 1}} = Tay.stats(name: @name)
    EngineHelpers.stop(root)
  end

  test "lifecycle telemetry is bounded and excludes job payloads", %{path: path} do
    handler = "inspection-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:tay, :job, :transition], [:tay, :queue, :control]],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, root} = EngineHelpers.start(path, @name)
    {:ok, job} = EngineWorker.new(%{"secret" => "never emit"}) |> Tay.insert(name: @name)

    assert_receive {:telemetry, [:tay, :job, :transition], %{count: 1}, metadata}
    assert metadata.engine == @name
    assert metadata.operation == :insert
    assert metadata.state == :available
    assert metadata.job_id == job.id
    refute inspect(metadata) =~ "never emit"

    assert :ok = Tay.pause_queue(:default, name: @name)

    assert_receive {:telemetry, [:tay, :queue, :control], %{count: 1},
                    %{engine: @name, operation: :pause_queue, queue: "default"}}

    EngineHelpers.stop(root)
  end

  defp collect(acc, cursor, name) do
    options = [name: name, limit: 4] ++ if(cursor, do: [cursor: cursor], else: [])
    {:ok, %{jobs: jobs, next_cursor: next_cursor}} = Tay.jobs(options)

    if next_cursor,
      do: collect(acc ++ jobs, next_cursor, name),
      else: {acc ++ jobs, nil}
  end
end
