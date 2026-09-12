defmodule Tay.Engine.FaultTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Tay.Test.{NativeHelpers, EngineWorker}
  alias Tay.Test.EngineHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Storage.{Writer, Native}
  @name __MODULE__
  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  for boundary <- [
        :pre_append,
        :post_append,
        {:projection, :queue_removed},
        {:projection, :schedule_removed},
        {:projection, :job_written},
        {:projection, :queue_written},
        {:projection, :schedule_written},
        :post_projection,
        :pre_reply
      ] do
    @boundary boundary
    @written boundary != :pre_append
    test "Engine death at #{inspect(boundary)} discards the whole view and replays the stored effect",
         %{path: path} do
      boundary = @boundary
      parent = self()

      hook = fn point ->
        if point == boundary do
          send(parent, {:boundary, self()})

          receive do
            :continue -> :ok
          end
        end
      end

      {:ok, root} = H.start(path, @name, test_hook: hook)
      engine = H.engine(root)
      state = :sys.get_state(engine)
      tables = [state.projection.jobs, state.projection.queue, state.projection.schedule]
      {:ok, intent} = EngineWorker.new(%{"secret" => "never logged"})
      task = Task.async(fn -> Tay.insert(intent, name: @name, timeout: 150) end)
      assert_receive {:boundary, ^engine}, 1000
      Process.exit(engine, :kill)
      assert {:error, %{kind: :unknown_outcome, job_id: id}} = Task.await(task)
      assert id == intent.id
      assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
      assert Enum.all?(tables, &(:ets.info(&1) == :undefined))
      assert {:error, %{kind: :unavailable}} = Tay.get_job(id, name: @name)
      H.stop(root)
      {:ok, next} = H.restart(path, @name)

      if @written do
        assert {:ok, %{state: :available, attempt: 0}} = Tay.get_job(id, name: @name)
      else
        assert {:error, :not_found} = Tay.get_job(id, name: @name)
      end

      assert {:ok, _} = Tay.insert(intent, name: @name)
      assert H.eventually(fn -> Tay.status(name: @name).jobs == 1 end)
      H.stop(next)
    end
  end

  for boundary <- [
        :activated,
        :indexes_created,
        :pre_ready,
        {:projection, :job_written},
        {:projection, :job_index_created},
        {:projection, :queue_index_created},
        {:projection, :scheduler_index_created}
      ] do
    @boundary boundary
    test "startup projection/publication failure at #{inspect(boundary)} never publishes readiness",
         %{path: path} do
      boundary = @boundary
      {:ok, root} = H.start(path, @name)
      {:ok, intent} = EngineWorker.new(%{})
      {:ok, _} = Tay.insert(intent, name: @name)
      H.stop(root)
      before = R.snapshot(path)
      hook = fn point -> if point == boundary, do: exit(:injected_startup_failure) end
      assert {:error, _} = H.restart(path, @name, test_hook: hook)
      assert Tay.status(name: @name).state == :unavailable
      assert R.snapshot(path) == before
      {:ok, root} = H.restart(path, @name)
      assert {:ok, _} = Tay.get_job(intent.id, name: @name)
      H.stop(root)
    end
  end

  test "an observed successful reply survives death before permit completion", %{path: path} do
    parent = self()

    hook = fn point ->
      if point == :post_reply do
        send(parent, {:replied, self()})

        receive do
          :continue -> :ok
        end
      end
    end

    {:ok, root} = H.start(path, @name, test_hook: hook)
    {:ok, intent} = EngineWorker.new(%{})
    assert {:ok, accepted} = Tay.insert(intent, name: @name)
    assert_receive {:replied, engine}
    Process.exit(engine, :kill)
    assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
    H.stop(root)
    {:ok, root} = H.restart(path, @name)
    assert {:ok, recovered} = Tay.get_job(accepted.id, name: @name)
    assert recovered.definition == accepted.definition
    H.stop(root)
  end

  test "poisoned-but-alive Writer closes gate before cleanup and revokes all indexes", %{
    path: path
  } do
    parent = self()

    hook = fn
      {:poisoned, _}, _ ->
        send(parent, {:poisoned_writer, self()})

        receive do
          :cleanup -> :ok
        end

      _, _ ->
        :ok
    end

    {:ok, root} = H.start(path, @name, writer_hook: hook)
    engine = H.engine(root)
    s = :sys.get_state(engine)
    # Hold poisoned Writer alive: revocation must not depend on Writer DOWN.
    assert Process.alive?(s.writer)
    os_pid = Writer.status(s.writer).os_pid
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert_receive {:poisoned_writer, writer}, 2000
    assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
    assert H.eventually(fn -> not Process.alive?(engine) end)
    assert :ets.info(s.projection.jobs) == :undefined
    assert Process.alive?(writer)
    send(writer, :cleanup)
    H.stop(root)
  end

  test "caller times out after durable append; explicit retry reconciles without another record",
       %{path: path} do
    parent = self()

    hook = fn point ->
      if point == :post_append do
        send(parent, {:committed, self()})

        receive do
          :continue -> :ok
        end
      end
    end

    {:ok, root} = H.start(path, @name, test_hook: hook, client_slots: 1)
    {:ok, intent} = EngineWorker.new(%{})
    task = Task.async(fn -> Tay.insert(intent, name: @name, timeout: 40) end)
    assert_receive {:committed, engine}
    assert {:error, %{kind: :unknown_outcome}} = Task.await(task)
    assert Tay.status(name: @name).client_slots_used == 1
    assert {:error, %{kind: :capacity}} = Tay.get_job(intent.id, name: @name)
    before = R.snapshot(path)
    send(engine, :continue)
    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
    assert {:ok, _} = Tay.insert(intent, name: @name)
    assert R.snapshot(path) == before
    H.stop(root)
  end

  for {action, count, recoverable} <- [
        {:error, 0, true},
        {:short, 19, false},
        {:crash_after, 0, true}
      ] do
    @action action
    @count count
    @recoverable recoverable
    test "native append #{@action} preserves evidence and unknown-outcome semantics", %{
      path: path
    } do
      {:ok, root} = H.start(path, @name)
      s = :sys.get_state(H.engine(root))
      assert :ok = Writer.inject_fault(s.writer, :write, 1, @action, 5, @count)
      {:ok, intent} = EngineWorker.new(%{})
      assert {:error, %{kind: :unknown_outcome}} = Tay.insert(intent, name: @name, timeout: 150)
      assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
      H.stop(root)
      before = R.snapshot(path)

      if @recoverable do
        assert {:ok, root} = H.restart(path, @name)

        if @action == :crash_after,
          do: assert(match?({:ok, _}, Tay.get_job(intent.id, name: @name)))

        if @action == :error,
          do: assert({:error, :not_found} == Tay.get_job(intent.id, name: @name))

        H.stop(root)
      else
        assert {:error, _} = H.restart(path, @name)
        assert Tay.status(name: @name).state == :unavailable
      end

      assert R.snapshot(path) == before
    end
  end

  @tag skip: System.get_env("TAY_TEST_SYNC") != "1"
  test "strict-sync failure after a complete append revokes, then replays despite no ACK", %{
    path: path
  } do
    hook = fn
      :append_written, native -> Native.fault(native, :sync, 1, :error, 5)
      _, _ -> :ok
    end

    {:ok, root} = H.start(path, @name, writer_hook: hook)
    {:ok, intent} = EngineWorker.new(%{})
    assert {:error, %{kind: :unknown_outcome}} = Tay.insert(intent, name: @name, timeout: 150)
    H.stop(root)
    {:ok, root} = H.restart(path, @name)
    assert {:ok, _} = Tay.get_job(intent.id, name: @name)
    H.stop(root)
  end

  test "pre-activation retained budget failure leaves every byte and name intact", %{path: path} do
    {:ok, root} = H.start(path, @name)
    {:ok, intent} = EngineWorker.new(%{})
    {:ok, _} = Tay.insert(intent, name: @name)
    H.stop(root)
    before = R.snapshot(path)

    for budget <- [[max_jobs: 0], [max_state_bytes: 1], [max_state_nodes: 1]] do
      assert {:error, _} = H.restart(path, @name, budget)
      assert R.snapshot(path) == before
      assert Tay.status(name: @name).state == :unavailable
    end

    {:ok, root} = H.restart(path, @name)
    assert {:ok, _} = Tay.get_job(intent.id, name: @name)
    H.stop(root)
  end
end
