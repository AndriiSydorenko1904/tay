defmodule Tay.Engine.SelectiveDurabilityTest do
  use ExUnit.Case, async: false

  alias Tay.Storage.Writer
  alias Tay.Test.{EngineHelpers, EngineWorker, ExecutionHelpers, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: Recovery

  @name __MODULE__

  defmodule VolatileWorker do
    use Tay.Worker, key: "volatile.worker.v1", durability: :volatile
    @impl true
    def perform(_), do: raise("selective durability fixture must not execute")
  end

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    Recovery.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "resolves job, worker, and global durability in that order", %{path: path} do
    root =
      with_global_durability(:volatile, fn ->
        {:ok, root} =
          EngineHelpers.start(path, @name,
            workers: %{
              "worker.v1" => EngineWorker,
              "volatile.worker.v1" => VolatileWorker
            }
          )

        root
      end)

    assert {:ok, global} = Tay.insert(EngineWorker, %{"source" => "global"}, name: @name)
    assert global.durability == :volatile

    assert {:ok, worker} = Tay.insert(VolatileWorker, %{"source" => "worker"}, name: @name)
    assert worker.durability == :volatile

    assert {:ok, explicit_job} =
             Tay.insert(VolatileWorker, %{"source" => "job"},
               name: @name,
               durability: :persistent
             )

    assert explicit_job.durability == :persistent

    assert {:ok, intent} = VolatileWorker.new(%{"source" => "request"})

    assert {:ok, request} =
             Tay.insert(intent, name: @name, durability: :persistent)

    assert request.durability == :persistent
    EngineHelpers.stop(root)
  end

  test "volatile insertion and cancellation never change persistent storage", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)
    engine = EngineHelpers.engine(root)
    before = writer_coordinates(engine)

    assert {:ok, job} =
             Tay.insert(EngineWorker, %{"kind" => "volatile"},
               name: @name,
               durability: :volatile
             )

    assert job.durability == :volatile
    assert {:ok, cancelled} = Tay.cancel(job.id, name: @name, expected_revision: job.revision)
    assert cancelled.state == :cancelled
    assert cancelled.durability == :volatile
    assert writer_coordinates(engine) == before

    assert %{jobs: 1, active_jobs: 0, terminal_jobs: 1, volatile_jobs: 1} =
             Tay.status(name: @name)

    state = :sys.get_state(engine)
    assert Tay.State.JobIndex.count(state.projection.jobs) == 1
    assert Tay.State.TerminalStore.count(state.terminal_store) == 0

    EngineHelpers.stop(root)
    {:ok, root} = EngineHelpers.restart(path, @name)
    assert {:error, :not_found} = Tay.get_job(job.id, name: @name)
    assert Tay.status(name: @name).jobs == 0
    EngineHelpers.stop(root)
  end

  test "volatile jobs remain subject to the shared state-memory limit", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name, max_state_bytes: 1)
    engine = EngineHelpers.engine(root)
    before = writer_coordinates(engine)

    assert {:error, %{kind: :capacity, reason: :retained_bytes}} =
             Tay.insert(EngineWorker, %{"too" => "large"},
               name: @name,
               durability: :volatile
             )

    assert writer_coordinates(engine) == before
    assert Tay.status(name: @name).jobs == 0
    EngineHelpers.stop(root)
  end

  test "protocol producers can select volatile durability", %{path: path} do
    socket = path <> ".sock"
    {:ok, root} = EngineHelpers.start(path, @name, executor_socket: socket)
    engine = EngineHelpers.engine(root)
    server = :sys.get_state(engine).executor_server
    before = writer_coordinates(engine)

    assert {:ok, "enqueued", %{"job" => job}} =
             Tay.Protocol.Service.handle(%{engine: @name, executor: server}, %{
               "type" => "enqueue",
               "task" => "remote.volatile.v1",
               "args" => %{},
               "options" => %{"durability" => "volatile"}
             })

    assert job["durability"] == "volatile"
    assert writer_coordinates(engine) == before

    assert {:error, "invalid_enqueue"} =
             Tay.Protocol.Service.handle(%{engine: @name, executor: server}, %{
               "type" => "enqueue",
               "task" => "remote.invalid.v1",
               "args" => %{},
               "options" => %{"durability" => "sync"}
             })

    EngineHelpers.stop(root)
  end

  test "mixed compaction retains volatile RAM state but recovery restores only persistent jobs",
       %{
         path: path
       } do
    {:ok, root} = EngineHelpers.start(path, @name)
    assert {:ok, persistent_intent} = EngineWorker.new(%{"kind" => "persistent"})
    assert {:ok, persistent} = Tay.insert(persistent_intent, name: @name)

    assert {:ok, volatile} =
             Tay.insert(EngineWorker, %{"kind" => "volatile"},
               name: @name,
               durability: :volatile
             )

    assert {:ok, persistent} =
             Tay.cancel(persistent.id, name: @name, expected_revision: persistent.revision)

    assert {:ok, volatile} =
             Tay.cancel(volatile.id, name: @name, expected_revision: volatile.revision)

    assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000, terminal_retention: :infinity)

    assert {:ok, %{durability: :persistent, state: :cancelled}} =
             Tay.get_job(persistent.id, name: @name)

    assert {:ok, %{durability: :volatile, state: :cancelled}} =
             Tay.get_job(volatile.id, name: @name)

    EngineHelpers.stop(root)

    {:ok, volatile_raw} = Tay.JobID.decode(volatile.id)
    {:ok, persistent_raw} = Tay.JobID.decode(persistent.id)
    recovered = ExecutionHelpers.replay(path)
    refute Map.has_key?(recovered.jobs, volatile_raw)
    assert Map.has_key?(recovered.jobs, persistent_raw)

    {:ok, root} = EngineHelpers.restart(path, @name)

    assert {:ok, %{durability: :persistent, state: :cancelled}} =
             Tay.get_job(persistent.id, name: @name)

    assert {:error, :not_found} = Tay.get_job(volatile.id, name: @name)
    EngineHelpers.stop(root)
  end

  test "zero-retention compaction removes finished volatile jobs from ETS", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)

    assert {:ok, finished} =
             Tay.insert(EngineWorker, %{"kind" => "finished volatile"},
               name: @name,
               durability: :volatile
             )

    assert {:ok, %{state: :cancelled}} =
             Tay.cancel(finished.id, name: @name, expected_revision: finished.revision)

    assert {:ok, active} =
             Tay.insert(EngineWorker, %{"kind" => "active volatile"},
               name: @name,
               durability: :volatile,
               scheduled_at: 5_000_000
             )

    assert %{jobs: 2, active_jobs: 1, terminal_jobs: 1, volatile_jobs: 2} =
             Tay.status(name: @name)

    assert {:ok, _} =
             Tay.compact(name: @name, timeout: 60_000, terminal_retention: {:hours, 0})

    assert {:error, :not_found} = Tay.get_job(finished.id, name: @name)

    assert {:ok, %{state: active_state, durability: :volatile}} =
             Tay.get_job(active.id, name: @name)

    assert active_state in [:available, :scheduled]

    assert %{jobs: 1, active_jobs: 1, terminal_jobs: 0, volatile_jobs: 1} =
             Tay.status(name: @name)

    assert {:ok, %{completed: 0, cancelled: 0, discarded: 0}} = Tay.stats(name: @name)

    state = :sys.get_state(EngineHelpers.engine(root))
    assert Tay.State.JobIndex.count(state.projection.jobs) == 1
    assert state.volatile_terminal_budget == %{count: 0, bytes: 0}
    EngineHelpers.stop(root)
  end

  test "volatile execution and retry use the shared state machine without journal writes", %{
    path: path
  } do
    ExecutionHelpers.install(100)
    {:ok, root} = ExecutionHelpers.start(path, @name)
    engine = ExecutionHelpers.engine(root)
    before = writer_coordinates(engine)
    {intent, token} = ExecutionHelpers.job(durability: :volatile, max_attempts: 2)
    assert {:ok, job} = Tay.insert(intent, name: @name)
    {task, %{attempt: 1}} = ExecutionHelpers.await_entry(token)
    send(task, {:return, {:error, :first_attempt}})
    retryable = ExecutionHelpers.await_job(@name, job.id, :retryable)
    assert retryable.durability == :volatile

    ExecutionHelpers.tick(root, 2_000)
    {task, %{attempt: 2}} = ExecutionHelpers.await_entry(token)
    send(task, {:return, :ok})
    completed = ExecutionHelpers.await_job(@name, job.id, :completed)
    assert completed.durability == :volatile
    assert writer_coordinates(engine) == before
    ExecutionHelpers.stop(root)
  end

  defp writer_coordinates(engine) do
    state = :sys.get_state(engine)
    writer = Writer.status(state.writer)
    {state.next_sequence, state.history_bytes, writer.next_sequence}
  end

  defp with_global_durability(mode, fun) do
    previous = Application.fetch_env(:tay, :durability)
    Application.put_env(:tay, :durability, mode)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:tay, :durability, value)
        :error -> Application.delete_env(:tay, :durability)
      end
    end
  end
end
