defmodule Tay.Execution.ControlTest do
  use ExUnit.Case, async: false
  alias Tay.Engine.Admission
  alias Tay.Test.{ExecutionHelpers, ExecutionWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R
  alias ExecutionHelpers, as: H
  @moduletag capture_log: true
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    path = NativeHelpers.path()
    H.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, options \\ []) do
    assert {:ok, root} = H.start(path, @name, options)
    on_exit(fn -> H.stop(root) end)
    root
  end

  defp controls(root), do: :sys.get_state(H.engine(root)).controls

  test "removed and mapped-unavailable workers or queues never block later executable jobs", %{
    path: path
  } do
    unavailable = Tay.Execution.ControlTest.NoCallbackModule

    workers = %{
      "execution.test.v1" => ExecutionWorker,
      "removed" => unavailable,
      "unavailable" => unavailable
    }

    root = start(path, test_execution: false, workers: workers)

    blocked =
      for key <- ["removed", "unavailable"] do
        assert {:ok, job} = Tay.Job.new(unavailable, %{}, worker_key: key)
        assert {:ok, _} = Tay.insert(job, name: @name)
        job
      end

    {removed_queue, removed_token} = H.job(queue: :removed)
    assert {:ok, _} = Tay.insert(removed_queue, name: @name)
    {valid, valid_token} = H.job()
    assert {:ok, _} = Tay.insert(valid, name: @name)
    H.stop(root)

    root = start(path, workers: Map.delete(workers, "removed"))
    {task, _} = H.await_entry(valid_token)
    assert H.entries(removed_token) == 0
    assert Tay.status(name: @name).blocked_jobs == 3
    assert H.eventually(fn -> Tay.status(name: @name).queue_slots_used == %{"default" => 1} end)

    for job <- [removed_queue | blocked] do
      assert {:ok, %{state: :available, attempt: 0, definition: definition}} =
               Tay.get_job(job.id, name: @name)

      assert definition == job.definition
    end

    send(task, {:return, :ok})
    H.await_job(@name, valid.id, :completed)
    H.stop(root)
    assert Enum.count(H.history(path), &(&1.event.record_type == 3)) == 1
  end

  test "queue and scheduler restart retain Engine slots and establish fresh bounded demand", %{
    path: path
  } do
    root = start(path, queues: [default: 2])
    {first, token1} = H.job()
    {second, token2} = H.job()
    {third, token3} = H.job()
    {scheduled, token4} = H.job(scheduled_at: 1_010_000)

    for job <- [first, second, third, scheduled],
        do: assert({:ok, _} = Tay.insert(job, name: @name))

    {task1, _} = H.await_entry(token1)
    {task2, _} = H.await_entry(token2)
    engine = H.engine(root)
    before = :sys.get_state(engine)
    queue = before.controls[{:queue, "default"}]
    scheduler = before.controls.scheduler
    Process.exit(queue, :kill)
    Process.exit(scheduler, :kill)

    assert H.eventually(fn ->
             current = controls(root)
             current[{:queue, "default"}] != queue and current.scheduler != scheduler
           end)

    assert H.engine(root) == engine
    assert :sys.get_state(engine).writer == before.writer
    assert H.eventually(fn -> Tay.status(name: @name).queue_slots_used == %{"default" => 2} end)
    assert H.entries(token3) == 0 and H.entries(token4) == 0
    assert Process.alive?(task1) and Process.alive?(task2)
    send(task1, {:return, :ok})
    {task3, _} = H.await_entry(token3)
    H.tick(root, 1_010_000)
    H.await_job(@name, scheduled.id, :available)
    assert H.entries(token4) == 0
    send(task2, {:return, :ok})
    {task4, _} = H.await_entry(token4)
    assert H.eventually(fn -> Tay.status(name: @name).queue_slots_used == %{"default" => 2} end)
    send(task3, {:return, :ok})
    send(task4, {:return, :ok})
    for job <- [first, second, third, scheduled], do: H.await_job(@name, job.id, :completed)
    assert H.eventually(fn -> Tay.status(name: @name).running_executions == 0 end)
    assert Enum.all?([token1, token2, token3, token4], &(H.entries(&1) == 1))
    H.stop(root)
  end

  test "suspended control processes receive coalesced wakeups across many ordinary client commands",
       %{path: path} do
    root = start(path, execution_wake_ms: 1000)
    coordinators = Map.values(controls(root))
    Enum.each(coordinators, &:sys.suspend/1)

    try do
      baseline =
        Map.new(coordinators, fn pid -> {pid, elem(Process.info(pid, :message_queue_len), 1)} end)

      for _ <- 1..64 do
        {job, _} = H.job(scheduled_at: 2_000_000)
        assert {:ok, _} = Tay.insert(job, name: @name)
        assert {:ok, %{state: :scheduled}} = Tay.get_job(job.id, name: @name)
      end

      for pid <- coordinators do
        {:message_queue_len, count} = Process.info(pid, :message_queue_len)
        # One coalesced wake, an already-in-flight ACK, and a previously armed
        # timer are permitted; the 128 client operations cannot add 128 casts.
        assert count <= baseline[pid] + 3
      end

      assert MapSet.size(:sys.get_state(H.engine(root)).control_wakes) <= 2
      assert Tay.status(name: @name).execution_control_slots == 2
      assert Tay.status(name: @name).running_executions == 0
    after
      Enum.each(coordinators, fn pid -> if Process.alive?(pid), do: :sys.resume(pid) end)
    end

    H.stop(root)
  end

  test "a suspended guardian receives at most one execution snapshot while full-queue controls poll",
       %{path: path} do
    root = start(path)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    guardian = Process.whereis(@name)
    engine = H.engine(root)
    :sys.suspend(guardian)

    try do
      # Full queue + idle scheduler do not call the suspended guardian. Their
      # periodic progress must not create an unbounded status-report backlog.
      assert H.eventually(fn -> :sys.get_state(engine).snapshot_dirty end)
      Process.sleep(150)
      {:messages, messages} = Process.info(guardian, :messages)

      assert Enum.count(messages, fn
               {:execution_snapshot, ^engine, _, _} -> true
               _ -> false
             end) <= 1

      state = :sys.get_state(engine)
      assert is_reference(state.snapshot_pending)
      assert state.snapshot_dirty
      assert map_size(state.running) == 1
      assert Process.alive?(task)
    after
      if Process.alive?(guardian), do: :sys.resume(guardian)
    end

    assert H.eventually(fn -> Tay.status(name: @name).running_executions == 1 end)
    send(task, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    H.stop(root)
  end

  test "capacity-refused due head preserves bytes and uses bounded wake interval, not a millisecond loop",
       %{path: path} do
    root = start(path, execution_wake_ms: 200)
    {job, token} = H.job(scheduled_at: 1_010_000)
    assert {:ok, _} = Tay.insert(job, name: @name)
    engine = H.engine(root)
    # Fault injection into the disposable operational budget only. A known
    # pre-I/O refusal must neither modify framing/bytes nor create an event.
    :sys.replace_state(engine, fn s -> put_in(s.budget.limits.max_bytes, 0) end)
    before = R.snapshot(path)
    :erlang.trace(engine, true, [:receive, {:tracer, self()}])

    count =
      try do
        H.tick(root, 1_010_000)
        count_scheduler_rechecks(engine, System.monotonic_time(:millisecond) + 350, 0)
      after
        :erlang.trace(engine, false, [:receive])
      end

    assert count in 1..4
    assert H.entries(token) == 0
    assert {:ok, %{state: :scheduled}} = Tay.get_job(job.id, name: @name)
    assert R.snapshot(path) == before
    assert Tay.status(name: @name).state == :ready
    H.stop(root)
  end

  test "two queues receive bounded demand fairly despite an earlier queue's backlog", %{
    path: path
  } do
    root = start(path, queues: [alpha: 2, beta: 1], execution_batch: 2)

    jobs =
      for queue <- List.duplicate(:alpha, 12) ++ List.duplicate(:beta, 3) do
        {job, token} = H.job(queue: queue, scheduled_at: 1_010_000)
        assert {:ok, _} = Tay.insert(job, name: @name)
        {job, token}
      end

    H.tick(root, 1_010_000)

    entered =
      for _ <- 1..3 do
        assert_receive {:tay_test_entered, token, task, metadata}, 5000
        {token, task, metadata}
      end

    assert Enum.frequencies_by(entered, fn {_, _, meta} -> meta.queue end) == %{alpha: 2, beta: 1}

    assert H.eventually(fn ->
             Tay.status(name: @name).queue_slots_used == %{"alpha" => 2, "beta" => 1}
           end)

    assert Tay.status(name: @name).execution_outcome_slots == 3
    assert Tay.status(name: @name).execution_control_slots == 3
    refute_receive {:tay_test_entered, _, _, _}, 30
    {_, beta_task, _} = Enum.find(entered, fn {_, _, meta} -> meta.queue == :beta end)
    send(beta_task, {:return, :ok})
    assert_receive {:tay_test_entered, next_token, next_beta, %{queue: :beta}}, 5000
    assert H.entries(next_token) == 1
    assert Enum.count(jobs, fn {_, token} -> H.entries(token) > 0 end) == 4
    assert Process.alive?(next_beta)

    assert Enum.all?(entered, fn {_, task, meta} ->
             meta.queue == :beta or Process.alive?(task)
           end)

    H.stop(root)
  end

  test "fully occupied client admission cannot prevent scheduled availability or durable outcomes",
       %{path: path} do
    root = start(path, client_slots: 2, client_bytes: 4096)
    {first, token1} = H.job()
    {second, token2} = H.job(scheduled_at: 1_010_000)
    assert {:ok, _} = Tay.insert(first, name: @name)
    {task1, _} = H.await_entry(token1)
    assert {:ok, _} = Tay.insert(second, name: @name)
    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
    {:ok, meta} = Admission.metadata(@name)

    permits =
      for _ <- 1..meta.slots do
        assert {:ok, permit} = Admission.claim(@name, meta, 5000)
        assert :ok = GenServer.call(meta.guardian, {:reserve, meta.generation, permit})
        permit
      end

    try do
      for _ <- 1..20 do
        assert {:error, %{kind: :capacity, reason: :client_slots}} =
                 Tay.get_job(first.id, name: @name)
      end

      assert {:error, %{kind: :capacity, reason: :client_slots}} = Tay.insert(first, name: @name)
      H.tick(root, 1_010_000)
      send(task1, {:return, :ok})
      {task2, _} = H.await_entry(token2)
      assert not Process.alive?(task1)
      assert Process.alive?(task2)
      assert Tay.status(name: @name).client_slots_used == 2
      assert H.eventually(fn -> Tay.status(name: @name).running_executions == 1 end)
      send(task2, {:return, :ok})
      assert H.eventually(fn -> Tay.status(name: @name).running_executions == 0 end)
    after
      for permit <- permits, do: send(meta.guardian, {:cancel_reservation, self(), permit})
    end

    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
    H.await_job(@name, first.id, :completed)
    H.await_job(@name, second.id, :completed)
    assert H.entries(token1) == 1 and H.entries(token2) == 1
    H.stop(root)
    assert Enum.count(H.history(path), &(&1.event.record_type == 2)) == 1
    assert Enum.count(H.history(path), &(&1.event.record_type == 4)) == 2
  end

  defp count_scheduler_rechecks(engine, deadline, count) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      count
    else
      receive do
        {:trace, ^engine, :receive, {:execution_control, :scheduler, _, _, _}} ->
          count_scheduler_rechecks(engine, deadline, count + 1)

        {:trace, ^engine, :receive, _} ->
          count_scheduler_rechecks(engine, deadline, count)
      after
        remaining -> count
      end
    end
  end
end
