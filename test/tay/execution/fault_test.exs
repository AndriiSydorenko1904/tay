defmodule Tay.Execution.FaultTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.NativeHelpers
  alias Tay.Storage.Writer
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    path = H.initialize(NativeHelpers.path())
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, options \\ []) do
    assert {:ok, root} = H.start(path, @name, options)
    on_exit(fn -> H.stop(root) end)
    root
  end

  defp barrier(parent, target) do
    fn point ->
      if point == target do
        send(parent, {:fault_boundary, point, self()})

        receive do
          :continue -> :ok
        end
      end
    end
  end

  defp revoked(root) do
    assert H.eventually(fn -> Tay.status(name: @name).state in [:failed, :unavailable] end)
    H.stop(root)
  end

  defp domain(path, id) do
    {:ok, raw} = Tay.JobID.decode(id)
    H.replay(path).jobs[raw]
  end

  for point <- [
        {:execution, :task_waiting},
        {:execution, 3, :pre_append},
        {:execution, 3, :post_append},
        {:execution, 3, :post_projection},
        {:execution, :pre_release},
        {:execution, :released}
      ] do
    @point point
    @started point not in [{:execution, :task_waiting}, {:execution, 3, :pre_append}]
    test "start boundary #{inspect(point)} preserves authorization and logical attempt", %{
      path: path
    } do
      root = start(path, test_hook: barrier(self(), @point))
      {job, token} = H.job()
      assert {:ok, _} = Tay.insert(job, name: @name)
      assert_receive {:fault_boundary, @point, engine}, 5_000

      unless @point == {:execution, :released}, do: assert(H.entries(token) == 0)
      Process.exit(engine, :kill)
      revoked(root)
      stored = domain(path, job.id)
      assert stored.state == if(@started, do: :executing, else: :available)
      assert stored.attempt == if(@started, do: 1, else: 0)
      previous_entries = H.entries(token)

      # The previous release may already have produced its separate side-effect
      # observation. Drain only before a new generation can start another task.
      receive do
        {:tay_test_entered, ^token, old, _} -> refute Process.alive?(old)
      after
        0 -> :ok
      end

      root = start(path)

      if @started do
        recovered = H.await_job(@name, job.id, :retryable)
        assert recovered.attempt == 1
        assert H.entries(token) == previous_entries
        H.tick(root, H.due(recovered))
      end

      {task, metadata} = H.await_entry(token)
      assert metadata.attempt == 1
      send(task, {:return, :ok})
      H.await_job(@name, job.id, :completed)
      H.stop(root)
    end
  end

  for point <- [:pre_append, :post_append, :post_projection] do
    @point point
    test "external effect then finish #{point} crash distinguishes effect from durable completion",
         %{path: path} do
      root = start(path, test_hook: barrier(self(), {:execution, 4, @point}))
      {job, token} = H.job()
      {:ok, _} = Tay.insert(job, name: @name)
      {task, _} = H.await_entry(token)
      assert H.entries(token) == 1
      send(task, {:return, :ok})
      assert_receive {:fault_boundary, {:execution, 4, @point}, engine}, 5_000
      Process.exit(engine, :kill)
      revoked(root)

      assert domain(path, job.id).state ==
               if(@point == :pre_append, do: :executing, else: :completed)

      root = start(path)

      if @point == :pre_append do
        retryable = H.await_job(@name, job.id, :retryable)
        assert retryable.attempt == 1
        H.tick(root, H.due(retryable))
        {task, metadata} = H.await_entry(token)
        assert metadata.attempt == 1
        assert H.entries(token) == 2
        send(task, {:return, :ok})
        H.await_job(@name, job.id, :completed)
      else
        H.await_job(@name, job.id, :completed)
        assert H.entries(token) == 1
      end

      H.stop(root)
    end
  end

  for operation <- [:cancel, :retry], point <- [:pre_append, :post_append, :post_projection] do
    @operation operation
    @event_type if(operation == :cancel, do: 5, else: 6)
    @point point
    test "#{operation} #{point} crash replays exactly the committed transition", %{path: path} do
      root = start(path, test_hook: barrier(self(), {:execution, @event_type, @point}))
      {job, token} = H.job(max_attempts: 1)
      {:ok, _} = Tay.insert(job, name: @name)
      {task, _} = H.await_entry(token)

      before =
        if @operation == :retry do
          send(task, {:return, {:error, :observed_failure}})
          H.await_job(@name, job.id, :discarded)
        else
          H.await_job(@name, job.id, :executing)
        end

      caller =
        Task.async(fn ->
          apply(Tay, @operation, [
            job.id,
            [name: @name, expected_revision: before.revision, timeout: 100]
          ])
        end)

      assert_receive {:fault_boundary, {:execution, @event_type, @point}, engine}, 5_000
      Process.exit(engine, :kill)
      assert {:error, %{kind: :unknown_outcome, expected_revision: revision}} = Task.await(caller)
      assert revision == before.revision
      revoked(root)

      expected =
        cond do
          @point == :pre_append -> before.state
          @operation == :cancel -> :cancelled
          true -> :available
        end

      assert domain(path, job.id).state == expected
      snapshot = R.snapshot(path)
      root = start(path, test_execution: false)
      assert {:ok, %{state: ^expected}} = Tay.get_job(job.id, name: @name)
      H.stop(root)
      assert R.snapshot(path) == snapshot
    end
  end

  for operation <- [:finish, :cancel, :retry], action <- [:error, :short, :crash_after] do
    @operation operation
    @action action
    test "#{operation} native #{@action} preserves complete records or torn evidence", %{
      path: path
    } do
      root = start(path)
      {job, token} = H.job(max_attempts: 1)
      {:ok, _} = Tay.insert(job, name: @name)
      {task, _} = H.await_entry(token)

      before =
        if @operation == :retry do
          send(task, {:return, {:error, :observed_failure}})
          H.await_job(@name, job.id, :discarded)
        else
          H.await_job(@name, job.id, :executing)
        end

      state = :sys.get_state(H.engine(root))

      :ok =
        Writer.inject_fault(
          state.writer,
          :write,
          1,
          @action,
          5,
          if(@action == :short, do: 19, else: 0)
        )

      if @operation == :finish do
        send(task, {:return, :ok})
      else
        assert {:error, %{kind: :unknown_outcome}} =
                 apply(Tay, @operation, [
                   job.id,
                   [name: @name, expected_revision: before.revision, timeout: 150]
                 ])
      end

      revoked(root)
      assert H.eventually(fn -> not Process.alive?(task) end)
      snapshot = R.snapshot(path)

      if @action == :short do
        assert {:error, _} = H.start(path, @name)
        assert Tay.status(name: @name).state == :unavailable
      else
        expected =
          cond do
            @action == :error -> before.state
            @operation == :finish -> :completed
            @operation == :cancel -> :cancelled
            true -> :available
          end

        root = start(path, test_execution: false)
        assert {:ok, %{state: ^expected}} = Tay.get_job(job.id, name: @name)
        H.stop(root)
        assert domain(path, job.id).state == expected
      end

      assert R.snapshot(path) == snapshot
    end
  end

  for component <- [:engine, :guardian, :writer, :native_helper, :runtime, :relay, :task] do
    @component component
    test "independent #{component} death keeps worker versus infrastructure classification", %{
      path: path
    } do
      root = start(path)
      {job, token} = H.job()
      {:ok, _} = Tay.insert(job, name: @name)
      {task, _} = H.await_entry(token)
      send(task, :trap_exits)
      state = :sys.get_state(H.engine(root))
      {relay, _} = H.runtime_entry(root, job.id)

      case @component do
        :engine ->
          Process.exit(H.engine(root), :kill)

        :native_helper ->
          System.cmd("kill", ["-KILL", Integer.to_string(Writer.status(state.writer).os_pid)])

        :task ->
          Process.exit(task, :kill)

        :relay ->
          Process.exit(relay, :kill)

        other ->
          Process.exit(Map.fetch!(state, other), :kill)
      end

      if @component == :task do
        retryable = H.await_job(@name, job.id, :retryable)
        assert retryable.attempt == 1
        assert Tay.status(name: @name).state == :ready
        H.stop(root)
        stored = domain(path, job.id)
        assert stored.next_attempt == 2
        assert stored.diagnostic == %{"code" => 4, "version" => 1}
      else
        revoked(root)
        assert H.eventually(fn -> not Process.alive?(task) end)
        assert domain(path, job.id).state == :executing
        root = start(path)
        H.await_job(@name, job.id, :retryable)
        H.stop(root)
        stored = domain(path, job.id)
        assert stored.attempt == 1 and stored.next_attempt == 1
        assert stored.diagnostic == %{"code" => 7, "version" => 1}
      end
    end
  end

  for operation <- [:start, :available, :retry_outcome],
      action <- [:error, :short, :crash_after] do
    @operation operation
    @action action
    test "#{operation} native #{@action} cannot publish a state beyond durable history", %{
      path: path
    } do
      root =
        start(
          path,
          if(@operation == :start,
            do: [test_hook: barrier(self(), {:execution, :task_waiting})],
            else: []
          )
        )

      writer = :sys.get_state(H.engine(root)).writer
      options = if @operation == :available, do: [scheduled_at: H.clock(:wall) + 10_000], else: []
      {job, token} = H.job(options)
      {:ok, _} = Tay.insert(job, name: @name)

      target =
        case @operation do
          :start ->
            assert_receive {:fault_boundary, {:execution, :task_waiting}, engine}, 5_000
            engine

          :retry_outcome ->
            {task, _} = H.await_entry(token)
            task

          :available ->
            nil
        end

      :ok =
        Writer.inject_fault(writer, :write, 1, @action, 5, if(@action == :short, do: 19, else: 0))

      case @operation do
        :start -> send(target, :continue)
        :available -> H.tick(root, H.clock(:wall) + 10_000)
        :retry_outcome -> send(target, {:return, {:error, :worker_failure}})
      end

      revoked(root)
      assert H.entries(token) == if(@operation == :retry_outcome, do: 1, else: 0)
      snapshot = R.snapshot(path)

      if @action == :short do
        assert {:error, _} = H.start(path, @name)
      else
        expected =
          case {@operation, @action} do
            {:start, :error} -> :available
            {:start, :crash_after} -> :executing
            {:available, :error} -> :scheduled
            {:available, :crash_after} -> :available
            {:retry_outcome, :error} -> :executing
            {:retry_outcome, :crash_after} -> :retryable
          end

        root = start(path, test_execution: false)
        assert {:ok, %{state: ^expected}} = Tay.get_job(job.id, name: @name)
        H.stop(root)

        if expected == :retryable do
          stored = domain(path, job.id)
          assert stored.next_attempt == 2
          assert stored.diagnostic == %{"code" => 1, "version" => 1}
        end
      end

      assert R.snapshot(path) == snapshot
    end
  end

  for operation <- [:cancel, :retry] do
    @operation operation
    test "#{operation} lost reply retains exact original revision and cannot repeat transition",
         %{path: path} do
      armed = :atomics.new(1, [])
      parent = self()

      hook = fn point ->
        if point == :pre_reply and :atomics.get(armed, 1) == 1 do
          send(parent, {:reply_waiting, self()})

          receive do
            :continue -> :ok
          end
        end
      end

      root = start(path, test_hook: hook)
      {job, token} = H.job(max_attempts: 1)
      {:ok, _} = Tay.insert(job, name: @name)
      {task, _} = H.await_entry(token)

      before =
        if @operation == :retry do
          send(task, {:return, {:error, :failure}})
          H.await_job(@name, job.id, :discarded)
        else
          H.await_job(@name, job.id, :executing)
        end

      :atomics.put(armed, 1, 1)

      caller =
        Task.async(fn ->
          apply(Tay, @operation, [
            job.id,
            [name: @name, expected_revision: before.revision, timeout: 50]
          ])
        end)

      assert_receive {:reply_waiting, engine}, 5_000
      assert {:error, %{kind: :unknown_outcome, expected_revision: revision}} = Task.await(caller)
      assert revision == before.revision
      Process.exit(engine, :kill)
      revoked(root)
      snapshot = R.snapshot(path)
      root = start(path, test_execution: false)

      assert {:error, %{kind: :conflict}} =
               apply(Tay, @operation, [job.id, [name: @name, expected_revision: revision]])

      assert {:ok, recovered} = Tay.get_job(job.id, name: @name)
      assert recovered.state == if(@operation == :cancel, do: :cancelled, else: :available)
      H.stop(root)
      assert R.snapshot(path) == snapshot
    end
  end

  @tag skip: System.get_env("TAY_TEST_SYNC") != "1"
  test "finish sync failure leaves complete unacknowledged outcome authoritative", %{path: path} do
    root = start(path)
    {job, token} = H.job()
    {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    writer = :sys.get_state(H.engine(root)).writer
    :ok = Writer.inject_fault(writer, :sync, 1, :error, 5)
    send(task, {:return, :ok})
    revoked(root)
    assert domain(path, job.id).state == :completed
    snapshot = R.snapshot(path)
    root = start(path)
    H.await_job(@name, job.id, :completed)
    assert H.entries(token) == 1
    H.stop(root)
    assert R.snapshot(path) == snapshot
  end

  test "durably started waiting task death revokes even while wall clock remains behind", %{
    path: path
  } do
    root = start(path, test_hook: barrier(self(), {:execution, 3, :post_projection}))
    {job, token} = H.job()
    {:ok, _} = Tay.insert(job, name: @name)
    assert_receive {:fault_boundary, {:execution, 3, :post_projection}, engine}, 5_000
    guardian = Process.whereis(@name)
    runtime = :sys.get_state(guardian).runtime
    [task] = Task.Supervisor.children(Tay.Execution.Supervisor.components(runtime).tasks)
    H.set_clock(0)
    Process.exit(task, :kill)
    send(engine, :continue)
    revoked(root)
    assert H.entries(token) == 0
    assert domain(path, job.id).state == :executing
  end
end
