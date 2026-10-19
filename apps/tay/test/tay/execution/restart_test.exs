defmodule Tay.Execution.RestartTest do
  use ExUnit.Case, async: false
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.{NativeHelpers, RecoveryHelpers}
  alias Tay.Engine.Admission
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

  defp start(path, extra \\ []) do
    {:ok, root} = H.start(path, @name, extra)
    on_exit(fn -> H.stop(root) end)
    root
  end

  test "graceful stop waits for durable settlement and death, preserves root and does not seal",
       %{path: path} do
    root = start(path)
    old = :sys.get_state(H.engine(root))
    guardian = Process.whereis(@name)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {worker, _} = H.await_entry(token)
    stopping = Task.async(fn -> Tay.stop(name: @name) end)
    assert H.eventually(fn -> Tay.status(name: @name).state == :draining end)
    assert Process.alive?(worker)
    assert Task.yield(stopping, 20) == nil
    {other, _} = H.job()
    assert {:error, %{kind: :unavailable}} = Tay.insert(other, name: @name)
    send(worker, {:return, :ok})
    assert :ok = Task.await(stopping)
    assert Process.alive?(root)
    assert Process.whereis(@name) == guardian
    assert Tay.status(name: @name).state == :stopped
    refute Process.alive?(worker)
    refute Process.alive?(old.writer)
    assert :ets.info(old.projection.jobs) == :undefined
    assert Enum.map(H.history(path), & &1.event.record_type) == [1, 3, 4]
    assert :ok = Tay.restart(name: @name)
    next = :sys.get_state(H.engine(root))
    refute next.generation == old.generation
    refute next.writer == old.writer
    refute next.admission == old.admission
    assert H.await_job(@name, job.id, :completed).attempt == 1
    assert :ok = Tay.stop(name: @name)
    H.stop(root)
  end

  test "explicit forced restart reuses ordinal but never old task, token, indexes or pending RPC",
       %{path: path} do
    root = start(path)
    {job, token} = H.job(max_attempts: 1)
    assert {:ok, _} = Tay.insert(job, name: @name)
    {first, entered1} = H.await_entry(token)
    old = :sys.get_state(H.engine(root))
    assert :ok = Tay.restart(name: @name, force: true)
    retryable = H.await_job(@name, job.id, :retryable)
    H.tick(root, H.due(retryable))
    {second, entered2} = H.await_entry(token)
    assert entered1.attempt == 1 and entered2.attempt == 1
    refute first == second
    refute Process.alive?(first)
    refute entered1.revision == entered2.revision
    assert :ets.info(old.projection.jobs) == :undefined
    assert H.entries(token) == 2
    send(second, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    assert :ok = Tay.stop(name: @name)
    events = H.history(path)
    assert Enum.map(events, & &1.event.record_type) == [1, 3, 4, 2, 3, 4]
    assert Enum.at(events, 2).event.data["diagnostic"] == %{"code" => 7, "version" => 1}
    H.stop(root)
  end

  test "graceful deadline leaves draining without a hidden later shutdown", %{path: path} do
    root = start(path)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {worker, _} = H.await_entry(token)
    stop = Task.async(fn -> Tay.stop(name: @name, timeout: 2000) end)
    assert H.eventually(fn -> Tay.status(name: @name).state == :draining end)
    guardian = Process.whereis(@name)
    operation = :sys.get_state(guardian).operation
    # Deterministically deliver the accepted deadline; this is a runtime timer
    # race test, not a sleep-based assumption about VM scheduling.
    send(guardian, {:operation_deadline, operation.token})
    assert {:error, %{kind: :timeout, reason: :draining}} = Task.await(stop)
    assert Process.alive?(worker)
    assert Tay.status(name: @name).state == :draining
    send(worker, {:return, :ok})
    assert H.eventually(fn -> Tay.status(name: @name).state == :drained end)
    assert Process.alive?(H.engine(root))
    assert :ok = Tay.stop(name: @name)
    H.stop(root)
  end

  test "force stop has independent capacity while every client slot holds a pending drain", %{
    path: path
  } do
    root = start(path, client_slots: 2, client_bytes: 4096)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {worker, _} = H.await_entry(token)
    drains = for _ <- 1..2, do: Task.async(fn -> Tay.drain(name: @name, timeout: 1000) end)
    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 2 end)
    assert :ok = Tay.stop(name: @name, force: true)
    refute Process.alive?(worker)
    assert Tay.status(name: @name).state == :stopped
    assert Tay.status(name: @name).client_slots_used == 0
    for drain <- drains, do: assert({:error, %{kind: :unknown_outcome}} = Task.await(drain))
    assert Enum.map(H.history(path), & &1.event.record_type) == [1, 3]
    H.stop(root)
  end

  test "caller loss during fresh activation keeps one operation and may finish once", %{
    path: path
  } do
    owner = self()
    :ets.insert(H, {:activations, 0})

    hook = fn
      :activated ->
        if :ets.update_counter(H, :activations, {2, 1}) == 2 do
          send(owner, {:activation_blocked, self()})
          receive do: (:continue -> :ok)
        end

      _ ->
        :ok
    end

    root = start(path, test_hook: hook, start_paused: true)
    old = :sys.get_state(H.engine(root))
    restart = Task.async(fn -> Tay.restart(name: @name, timeout: 200) end)
    assert_receive {:activation_blocked, next}, 5000
    assert {:error, %{kind: :unknown_outcome}} = Task.await(restart)
    assert :ets.info(old.projection.jobs) == :undefined
    assert Tay.status(name: @name).state == :recovering
    assert {:error, %{kind: :capacity, reason: :operation_slot}} = Tay.restart(name: @name)
    send(next, :continue)
    assert H.eventually(fn -> Tay.status(name: @name).state == :ready end)
    assert H.eventually(fn -> :sys.get_state(Process.whereis(@name)).operation == nil end)
    assert :ets.lookup_element(H, :activations, 2) == 2
    assert :ok = Tay.stop(name: @name)
    H.stop(root)
  end

  test "old generation operation and submitted metadata cannot target the fresh Engine", %{
    path: path
  } do
    root = start(path, start_paused: true)
    {:ok, old} = Admission.metadata(@name)
    assert {:ok, permit} = Admission.claim(@name, old, 5000)
    assert :ok = GenServer.call(old.guardian, {:reserve, old.generation, permit})
    assert :ok = Tay.restart(name: @name)
    before = RecoveryHelpers.snapshot(path)
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + 5000

    assert Admission.cas(
             @name,
             {:operation, nil, nil, :free, 0},
             {:operation, token, self(), :claimed, deadline}
           )

    assert {:error, %{reason: :operation_unavailable}} =
             GenServer.call(
               old.guardian,
               {:operation, old.generation, token, :stop, true, deadline}
             )

    assert {:error, _} =
             GenServer.call(
               old.guardian,
               {:submit, old.generation, permit, {:drain, deadline}}
             )

    assert Tay.status(name: @name).state == :ready
    assert RecoveryHelpers.snapshot(path) == before
    assert :ok = Tay.stop(name: @name)
    H.stop(root)
  end

  test "poisoned Writer during graceful stop reports generation loss, not successful drain", %{
    path: path
  } do
    root = start(path)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {worker, _} = H.await_entry(token)
    state = :sys.get_state(H.engine(root))
    stop = Task.async(fn -> Tay.stop(name: @name) end)
    assert H.eventually(fn -> Tay.status(name: @name).state == :draining end)
    send(state.guardian, {Tay.Storage.Writer, state.writer, :poisoned})
    assert {:error, %{kind: :unavailable, reason: :generation_lost}} = Task.await(stop)
    assert H.eventually(fn -> not Process.alive?(worker) end)
    assert Tay.status(name: @name).state == :failed
    H.stop(root)
  end

  test "fresh restart of an incomplete canonical suffix preserves every byte and fails closed", %{
    path: path
  } do
    root = start(path, start_paused: true)
    {job, _} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    assert :ok = Tay.stop(name: @name)
    File.write!(RecoveryHelpers.canonical(path, 1), <<1, 2, 3>>, [:append])
    before = RecoveryHelpers.snapshot(path)
    assert {:error, %{kind: :unavailable}} = Tay.restart(name: @name)
    assert Tay.status(name: @name).state == :failed
    assert RecoveryHelpers.snapshot(path) == before
    assert Process.alive?(root)
    assert H.engine(root) == nil
    H.stop(root)
  end

  test "trusted driver death during activation revokes the replacement generation", %{path: path} do
    owner = self()
    :ets.insert(H, {:activations, 0})

    hook = fn
      :activated ->
        if :ets.update_counter(H, :activations, {2, 1}) == 2 do
          send(owner, {:activation_blocked, self()})
          receive do: (:continue -> :ok)
        end

      _ ->
        :ok
    end

    root = start(path, test_hook: hook)
    restart = Task.async(fn -> Tay.restart(name: @name) end)
    assert_receive {:activation_blocked, replacement}, 5000
    guardian = Process.whereis(@name)
    driver = :sys.get_state(guardian).operation.driver
    Process.exit(driver, :kill)

    assert {:error, %{kind: :unknown_outcome, reason: :lifecycle_driver_lost}} =
             Task.await(restart)

    assert H.eventually(fn -> not Process.alive?(replacement) end)
    assert Tay.status(name: @name).state == :failed
    assert :sys.get_state(guardian).operation == nil
    H.stop(root)
  end

  test "dead operational claimant is reaped without changing storage or consuming client credits",
       %{path: path} do
    root = start(path, start_paused: true)
    before = RecoveryHelpers.snapshot(path)
    owner = self()

    claimant =
      spawn(fn ->
        token = make_ref()
        deadline = System.monotonic_time(:millisecond) + 10_000

        true =
          Admission.cas(
            @name,
            {:operation, nil, nil, :free, 0},
            {:operation, token, self(), :claimed, deadline}
          )

        send(owner, :claimed)
        receive do: (:finish -> :ok)
      end)

    assert_receive :claimed
    assert {:error, %{kind: :capacity, reason: :operation_slot}} = Tay.stop(name: @name)
    assert Tay.status(name: @name).client_slots_used == 0
    Process.exit(claimant, :kill)

    assert H.eventually(fn ->
             :ets.lookup(@name, :operation) == [{:operation, nil, nil, :free, 0}]
           end)

    assert RecoveryHelpers.snapshot(path) == before
    assert :ok = Tay.stop(name: @name)
    stopped = RecoveryHelpers.snapshot(path)
    assert :ok = Tay.stop(name: @name)
    assert RecoveryHelpers.snapshot(path) == stopped
    H.stop(root)
  end

  for component <- [:runtime, :fence] do
    @component component
    test "queued successful restart result cannot outrun replacement #{@component} death", %{
      path: path
    } do
      owner = self()

      hook = fn
        {:operations, :pre_result} ->
          send(owner, {:result_ready, self()})
          receive do: (:continue -> :ok)

        _ ->
          :ok
      end

      root = start(path, test_hook: hook, start_paused: true)
      restart = Task.async(fn -> Tay.restart(name: @name) end)
      assert_receive {:result_ready, driver}, 5000
      guardian = Process.whereis(@name)
      state = :sys.get_state(guardian)
      engine = state.engine
      :ok = :sys.suspend(engine)
      :ok = :sys.suspend(guardian)

      try do
        send(driver, :continue)

        assert H.eventually(fn ->
                 {:messages, messages} = Process.info(guardian, :messages)
                 Enum.any?(messages, &match?({:operation_result, ^driver, _, :ok}, &1))
               end)

        component =
          if @component == :runtime,
            do: state.runtime,
            else: Tay.Execution.LocalFence.guard(state.fence)

        Process.exit(component, :kill)
        assert H.eventually(fn -> not Process.alive?(component) end)
        assert Process.alive?(engine)
        assert Process.alive?(state.writer)
      after
        :ok = :sys.resume(guardian)
      end

      assert {:error, %{kind: :unavailable}} = Task.await(restart)
      assert H.eventually(fn -> not Process.alive?(engine) end)
      assert Tay.status(name: @name).state == :failed
      H.stop(root)
    end
  end

  test "legacy execution-disabled test generation can stop and rebuild with no runtime lease", %{
    path: path
  } do
    root = start(path, test_execution: false)
    {job, _} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    old = :sys.get_state(H.engine(root))
    assert old.runtime == nil and old.fence == nil
    assert :ok = Tay.restart(name: @name)
    refute :sys.get_state(H.engine(root)).generation == old.generation
    assert {:ok, %{state: :available}} = Tay.get_job(job.id, name: @name)
    assert :ok = Tay.stop(name: @name)
    H.stop(root)
  end
end
