defmodule Tay.Execution.LifecycleTest do
  use ExUnit.Case, async: false
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.NativeHelpers
  alias Tay.Test.RecoveryHelpers, as: R
  @moduletag capture_log: true
  @name __MODULE__
  @other Tay.Execution.LifecycleTest.Other

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    path = NativeHelpers.path()
    H.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  for {name, action, state, diagnostic} <- [
        {:ok, {:return, :ok}, :completed, nil},
        {:result, {:return, {:ok, :ignored_runtime_result}}, :completed, nil},
        {:error, {:return, {:error, :ignored_runtime_reason}}, :discarded, 1},
        {:raise, {:raise, :ignored_runtime_exception}, :discarded, 2},
        {:throw, {:throw, :ignored_runtime_throw}, :discarded, 3},
        {:exit, {:exit, :ignored_runtime_exit}, :discarded, 4},
        {:bad_return, {:return, :not_a_worker_result}, :discarded, 6}
      ] do
    @action action
    @state state
    @diagnostic diagnostic
    test "#{name} settles once through its approved bounded outcome", %{path: path} do
      {:ok, root} = H.start(path, @name)
      on_exit(fn -> H.stop(root) end)
      {job, token} = H.job(max_attempts: 1)
      assert {:ok, _} = Tay.insert(job, name: @name)
      {task, entered} = H.await_entry(token)
      assert entered.attempt == 1
      assert H.await_job(@name, job.id, :executing).revision == entered.revision
      send(task, @action)
      finished = H.await_job(@name, job.id, @state)
      assert finished.attempt == 1
      expected = if @diagnostic, do: [%{"code" => @diagnostic, "version" => 1}], else: []
      assert finished.errors == expected
      assert H.eventually(fn -> not Process.alive?(task) end)
      assert H.entries(token) == 1
      H.stop(root)
      assert Enum.map(H.history(path), & &1.event.record_type) == [1, 3, 4]
      {:ok, raw} = Tay.JobID.decode(job.id)
      assert H.replay(path).jobs[raw].state == @state
    end
  end

  test "stored timeout uses monotonic release time and persists code 5 once", %{path: path} do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    {job, token} = H.job(max_attempts: 1, timeout_ms: 50)
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    {relay, entry} = H.runtime_entry(root, job.id)
    H.set_clock(900_000, 49)
    send(relay, {:timeout, entry.ticket})
    assert :sys.get_state(relay).chosen == nil
    assert H.await_job(@name, job.id, :executing).attempt == 1
    H.set_clock(900_000, 50)
    send(relay, {:timeout, entry.ticket})
    finished = H.await_job(@name, job.id, :discarded)
    assert finished.errors == [%{"code" => 5, "version" => 1}]
    assert H.eventually(fn -> not Process.alive?(task) end)
    H.stop(root)
    [%{event: finish}] = Enum.filter(H.history(path), &(&1.event.record_type == 4))
    assert finish.data["outcome"] == 2
    assert finish.data["at"] == 900_000
  end

  test "huge callback terms and externally delivered exit reasons never enter storage or default logs",
       %{path: path} do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    secret = "PRIVATE_CALLBACK_ONLY_MARKER"
    huge = String.duplicate(secret, 80_000)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        for {action, expected_state, code} <- [
              {{:return, {:ok, huge}}, :completed, nil},
              {{:return, {:error, huge}}, :discarded, 1},
              {{:raise, huge}, :discarded, 2},
              {{:throw, huge}, :discarded, 3},
              {{:exit, huge}, :discarded, 4},
              {{:return, {:invalid, huge}}, :discarded, 6},
              {{:external_exit, huge}, :discarded, 4}
            ] do
          {job, token} = H.job(max_attempts: 1)
          assert {:ok, _} = Tay.insert(job, name: @name)
          {task, _} = H.await_entry(token)

          case action do
            {:external_exit, reason} -> Process.exit(task, reason)
            other -> send(task, other)
          end

          finished = H.await_job(@name, job.id, expected_state)
          assert finished.errors == if(code, do: [%{"code" => code, "version" => 1}], else: [])
          assert H.eventually(fn -> not Process.alive?(task) end)
          assert Tay.status(name: @name).state == :ready
        end
      end)

    refute String.contains?(logs, secret)
    H.stop(root)
    refute File.read!(R.canonical(path, 1)) =~ secret
    assert length(H.history(path)) == 21
  end

  test "automatic retry persists one choice and runs ordinal two only when due", %{path: path} do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    {job, token} = H.job(max_attempts: 2)
    assert {:ok, _} = Tay.insert(job, name: @name)
    {first, _} = H.await_entry(token)
    send(first, {:return, {:error, :failed}})
    retryable = H.await_job(@name, job.id, :retryable)
    due = H.due(retryable)
    assert due in 1_001_000..1_001_250
    H.tick(root, due - 1)
    refute_receive {:tay_test_entered, ^token, _, _}, 30
    H.tick(root, due)
    {second, entered} = H.await_entry(token)
    refute Process.alive?(first)
    assert entered.attempt == 2
    send(second, {:return, :ok})
    finished = H.await_job(@name, job.id, :completed)
    assert finished.errors == [%{"code" => 1, "version" => 1}]
    H.stop(root)
    history = H.history(path)
    assert Enum.map(history, & &1.event.record_type) == [1, 3, 4, 2, 3, 4]
    assert Enum.at(history, 2).event.data["next_due_at"] == due
    assert Enum.at(history, 3).event.data["due_at"] == due
  end

  test "equal scheduled deadlines use due/id order and backward time does not release early", %{
    path: path
  } do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    jobs = for _ <- 1..2, do: H.job(scheduled_at: 1_000_010)
    Enum.each(jobs, fn {job, _} -> assert {:ok, _} = Tay.insert(job, name: @name) end)
    H.tick(root, 900_000)
    refute_receive {:tay_test_entered, _, _, _}, 30
    H.tick(root, 1_000_009)
    refute_receive {:tay_test_entered, _, _, _}, 30
    H.tick(root, 1_000_010)

    for {job, token} <- Enum.sort_by(jobs, fn {job, _} -> job.id end) do
      {task, entered} = H.await_entry(token)
      assert entered.id == job.id
      send(task, {:return, :ok})
      H.await_job(@name, job.id, :completed)
    end

    H.stop(root)

    available_ids =
      H.history(path)
      |> Enum.filter(&(&1.event.record_type == 2))
      |> Enum.map(&Tay.JobID.encode(&1.event.data["job_id"]))

    assert available_ids == Enum.sort(available_ids)
  end

  test "scheduled cancellation is idempotent without another Event and cannot be retried", %{
    path: path
  } do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    {job, token} = H.job(scheduled_at: 2_000_000)
    assert {:ok, inserted} = Tay.insert(job, name: @name)

    assert {:ok, cancelled} =
             Tay.cancel(job.id, name: @name, expected_revision: inserted.revision)

    assert cancelled.state == :cancelled
    before = R.snapshot(path)

    assert {:ok, ^cancelled} =
             Tay.cancel(job.id, name: @name, expected_revision: cancelled.revision)

    assert {:error, %{kind: :conflict}} = Tay.retry(job.id, name: @name)
    assert R.snapshot(path) == before
    assert H.entries(token) == 0
    H.stop(root)
    assert Enum.map(H.history(path), & &1.event.record_type) == [1, 5]
  end

  test "executing cancellation fences late results and waits for actual callback death", %{
    path: path
  } do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, entered} = H.await_entry(token)
    send(task, :trap_exits)
    {relay, entry} = H.runtime_entry(root, job.id)
    engine = H.engine(root)
    generation = :sys.get_state(engine).generation

    assert {:ok, %{state: :cancelled}} =
             Tay.cancel(job.id, name: @name, expected_revision: entered.revision)

    assert H.eventually(fn -> not Process.alive?(task) end)

    send(
      engine,
      {:tay_execution, relay, entry.ticket, generation, entry.execution, {:outcome, :success}}
    )

    assert H.await_job(@name, job.id, :cancelled).attempt == 1
    assert H.entries(token) == 1
    H.stop(root)
    history = H.history(path)
    assert Enum.map(history, & &1.event.record_type) == [1, 3, 5]
    assert List.last(history).event.data["execution_token"] == entry.execution
  end

  test "manual expedite preserves ordinal/cycle and a stale second command cannot repeat it", %{
    path: path
  } do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    {job, token} = H.job(max_attempts: 2)
    assert {:ok, _} = Tay.insert(job, name: @name)
    {first, _} = H.await_entry(token)
    send(first, {:return, {:error, :failed}})
    retryable = H.await_job(@name, job.id, :retryable)

    assert {:ok, %{state: :available}} =
             Tay.retry(job.id, name: @name, expected_revision: retryable.revision)

    assert {:error, %{reason: :revision_conflict}} =
             Tay.retry(job.id, name: @name, expected_revision: retryable.revision)

    {second, entered} = H.await_entry(token)
    assert entered.attempt == 2
    refute Process.alive?(first)
    send(second, {:return, :ok})
    assert H.await_job(@name, job.id, :completed).definition == job.definition
    H.stop(root)
    history = H.history(path)
    starts = Enum.filter(history, &(&1.event.record_type == 3))
    assert Enum.map(starts, & &1.event.data["cycle_token"]) == [1, 1]
    [%{event: retried}] = Enum.filter(history, &(&1.event.record_type == 6))
    assert retried.data["mode"] == 0
  end

  test "manual retry of discarded work starts a new cycle without reusing a physical token", %{
    path: path
  } do
    {:ok, root} = H.start(path, @name)
    on_exit(fn -> H.stop(root) end)
    {job, token} = H.job(max_attempts: 1)
    assert {:ok, _} = Tay.insert(job, name: @name)
    {first, first_entry} = H.await_entry(token)
    send(first, {:return, {:error, :failed}})
    discarded = H.await_job(@name, job.id, :discarded)
    assert {:ok, _} = Tay.retry(job.id, name: @name, expected_revision: discarded.revision)
    {second, second_entry} = H.await_entry(token)
    assert first_entry.attempt == 1 and second_entry.attempt == 1
    refute first_entry.revision == second_entry.revision
    send(second, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    H.stop(root)
    history = H.history(path)

    [%{sequence: retry_sequence, event: event}] =
      Enum.filter(history, &(&1.event.record_type == 6))

    assert event.data["mode"] == 1
    starts = Enum.filter(history, &(&1.event.record_type == 3))
    assert Enum.map(starts, & &1.event.data["cycle_token"]) == [1, retry_sequence]
    assert Enum.uniq(Enum.map(starts, & &1.sequence)) == Enum.map(starts, & &1.sequence)
  end

  test "repeated infrastructure interruption reuses the ordinal even at max_attempts", %{
    path: path
  } do
    {:ok, root} = H.start(path, @name)
    {job, token} = H.job(max_attempts: 1)
    assert {:ok, _} = Tay.insert(job, name: @name)

    {root, revisions} =
      Enum.reduce(1..2, {root, []}, fn _, {root, revisions} ->
        {task, entered} = H.await_entry(token)
        assert entered.attempt == 1
        Process.exit(H.engine(root), :kill)
        assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
        assert H.eventually(fn -> not Process.alive?(task) end)
        H.stop(root)
        {:ok, next} = H.start(path, @name)
        interrupted = H.await_job(@name, job.id, :retryable)
        assert interrupted.attempt == 1
        assert interrupted.errors == [%{"code" => 7, "version" => 1}]
        H.tick(next, H.due(interrupted))
        {next, [entered.revision | revisions]}
      end)

    on_exit(fn -> H.stop(root) end)
    {task, entered} = H.await_entry(token)
    assert entered.attempt == 1
    assert entered.revision not in revisions
    send(task, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    H.stop(root)
    history = H.history(path)
    starts = Enum.filter(history, &(&1.event.record_type == 3))
    assert Enum.map(starts, & &1.event.data["attempt"]) == [1, 1, 1]
    assert length(Enum.uniq(Enum.map(starts, & &1.sequence))) == 3

    interrupted =
      Enum.filter(history, &(&1.event.record_type == 4 and &1.event.data["outcome"] == 3))

    assert length(interrupted) == 2
    assert Enum.all?(interrupted, &(&1.event.data["next_attempt"] == 1))
  end

  test "different instance name cannot publish a generation while the old local callback lives",
       %{
         path: path
       } do
    {:ok, old_root} = H.start(path, @name)
    on_exit(fn -> H.stop(old_root) end)
    {job, token} = H.job(max_attempts: 1)
    assert {:ok, _} = Tay.insert(job, name: @name)
    {old_task, old_entry} = H.await_entry(token)
    send(old_task, :trap_exits)
    Process.exit(H.engine(old_root), :kill)
    assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
    {:ok, next_root} = H.start(path, @other)
    on_exit(fn -> H.stop(next_root) end)
    refute Process.alive?(old_task)
    recovered = H.await_job(@other, job.id, :retryable)
    H.tick(next_root, H.due(recovered))
    {task, entry} = H.await_entry(token)
    assert entry.attempt == old_entry.attempt
    refute entry.revision == old_entry.revision
    refute Process.alive?(old_task)
    send(task, {:return, :ok})
    H.await_job(@other, job.id, :completed)
    H.stop(next_root)
    H.stop(old_root)
  end
end
