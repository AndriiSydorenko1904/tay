defmodule Tay.Engine.AvailabilityTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, ExecutionClock, ExecutionHelpers, NativeHelpers}
  @name __MODULE__
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install(1_000)
    path = NativeHelpers.path()
    ExecutionHelpers.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, extra \\ []) do
    {:ok, root} =
      ExecutionHelpers.start(
        path,
        @name,
        [test_clock: ExecutionClock, compaction: false] ++ extra
      )

    Process.unlink(root)
    on_exit(fn -> EngineHelpers.stop(root) end)
    root
  end

  defp insert(key, extra \\ []) do
    {job, token} = ExecutionHelpers.job([availability_key: key, max_attempts: :infinity] ++ extra)
    assert {:ok, job} = Tay.insert(job, name: @name)
    {job, token}
  end

  defp wait_state(id, state) do
    assert EngineHelpers.eventually(fn ->
             case Tay.get_job(id, name: @name) do
               {:ok, job} -> job.state == state
               _ -> false
             end
           end)

    {:ok, job} = Tay.get_job(id, name: @name)
    job
  end

  test "new work wakes only the matching dependency without waiting for its deadline", %{
    path: path
  } do
    start(path)
    {first, token} = insert("api")
    {task, _} = ExecutionHelpers.await_entry(token)
    send(task, {:return, {:unavailable, :offline}})
    wait_state(first.id, :retryable)

    assert EngineHelpers.eventually(fn ->
             Tay.status(name: @name).availability["api"]["status"] == "unavailable"
           end)

    {other, other_token} = insert("other")
    {other_task, _} = ExecutionHelpers.await_entry(other_token)
    send(other_task, {:return, {:unavailable, :offline}})
    wait_state(other.id, :retryable)

    {fresh, fresh_token} = insert("api")

    seen =
      for _ <- 1..2 do
        assert_receive {:tay_test_entered, entered, task, _}, 3_000
        assert entered in [token, fresh_token]
        send(task, {:return, :ok})
        entered
      end

    assert Enum.sort(seen) == Enum.sort([token, fresh_token])
    wait_state(first.id, :completed)
    wait_state(fresh.id, :completed)
    assert {:ok, %{state: :retryable}} = Tay.get_job(other.id, name: @name)
    assert ExecutionHelpers.entries(other_token) == 1
  end

  test "successful probe opens the gate and wakes remaining jobs across queues", %{path: path} do
    root = start(path, queues: [default: 2, another: 2])
    {first, token} = insert("api")
    {task, _} = ExecutionHelpers.await_entry(token)
    {second, second_token} = insert("api", queue: :another)
    {second_task, _} = ExecutionHelpers.await_entry(second_token)
    send(task, {:return, {:unavailable, :offline}})
    send(second_task, {:return, {:unavailable, :offline}})
    wait_state(first.id, :retryable)
    wait_state(second.id, :retryable)
    ExecutionHelpers.set_clock(2_300)
    Tay.Engine.Execution.wake_controls(:sys.get_state(EngineHelpers.engine(root)))

    {probe, _} =
      receive do
        {:tay_test_entered, ^token, task, metadata} -> {task, metadata}
        {:tay_test_entered, ^second_token, task, metadata} -> {task, metadata}
      after
        3_000 -> flunk("no probe")
      end

    refute_receive {:tay_test_entered, _, _, _}, 50
    send(probe, {:return, :ok})
    assert_receive {:tay_test_entered, remaining_token, remaining, _}, 3_000
    assert remaining_token in [token, second_token]
    send(remaining, {:return, :ok})
    wait_state(first.id, :completed)
    wait_state(second.id, :completed)
  end

  test "gate survives compaction, terminal expiry and restart", %{path: path} do
    root = start(path)
    {job, token} = insert("api")
    {task, _} = ExecutionHelpers.await_entry(token)
    send(task, {:return, {:unavailable, :offline}})
    wait_state(job.id, :retryable)
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    assert :ok = Tay.restart(name: @name)

    assert EngineHelpers.eventually(fn ->
             Tay.status(name: @name).availability["api"]["status"] == "unavailable"
           end)

    assert {:ok, %{state: :retryable}} = Tay.get_job(job.id, name: @name)
    refute_receive {:tay_test_entered, ^token, _, _}, 50

    # A durable new insertion opens the gate even if execution is paused. Both
    # the signal and blocked jobs survive another checkpoint and full stop.
    assert :ok = Tay.pause_queue(:default, name: @name)
    {fresh, fresh_token} = insert("api")
    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: {:hours, 0})
    EngineHelpers.stop(root)
    start(path)
    assert Tay.status(name: @name).availability["api"]["status"] == "available"

    seen =
      for _ <- 1..2 do
        assert_receive {:tay_test_entered, entered, task, _}, 3_000
        send(task, {:return, :ok})
        entered
      end

    assert Enum.sort(seen) == Enum.sort([token, fresh_token])
    wait_state(job.id, :completed)
    wait_state(fresh.id, :completed)
  end

  test "cancelling the last deferred job allows another queued job to probe", %{path: path} do
    root = start(path)
    {first, token} = insert("api")
    {task, _} = ExecutionHelpers.await_entry(token)
    {second, second_token} = insert("api")
    send(task, {:return, {:unavailable, :offline}})
    first = wait_state(first.id, :retryable)
    assert {:ok, _} = Tay.cancel(first.id, name: @name, expected_revision: first.revision)
    refute_receive {:tay_test_entered, ^second_token, _, _}, 50
    ExecutionHelpers.tick(root, 2_300)
    {probe, _} = ExecutionHelpers.await_entry(second_token)
    send(probe, {:return, :ok})
    wait_state(second.id, :completed)
  end

  test "opening a gate does not reset ordinary errors or explicit schedules", %{path: path} do
    start(path)
    {failed, token} = insert("api")
    {task, _} = ExecutionHelpers.await_entry(token)
    send(task, {:return, {:error, :business_error}})
    failed = wait_state(failed.id, :retryable)
    {scheduled, scheduled_token} = insert("api", scheduled_at: 50_000)
    {fresh, fresh_token} = insert("api")
    {fresh_task, _} = ExecutionHelpers.await_entry(fresh_token)
    send(fresh_task, {:return, :ok})
    wait_state(fresh.id, :completed)
    assert {:ok, current} = Tay.get_job(failed.id, name: @name)
    assert current.state == :retryable
    assert current.scheduled_at == failed.scheduled_at
    assert {:ok, %{state: :scheduled}} = Tay.get_job(scheduled.id, name: @name)
    assert ExecutionHelpers.entries(token) == 1
    assert ExecutionHelpers.entries(scheduled_token) == 0
  end

  test "a signal wakes more than one batch without advancing the retry clock", %{path: path} do
    start(path, queues: [default: 64])

    waiting =
      for _ <- 1..40 do
        {job, token} = insert("api")
        {task, _} = ExecutionHelpers.await_entry(token)
        {job, token, task}
      end

    for {_, _, task} <- waiting, do: send(task, {:return, {:unavailable, :offline}})
    for {job, _, _} <- waiting, do: wait_state(job.id, :retryable)
    {fresh, fresh_token} = insert("api")
    tokens = for {_, token, _} <- waiting, do: token

    seen =
      for _ <- 1..41 do
        assert_receive {:tay_test_entered, token, task, _}, 3_000
        send(task, {:return, :ok})
        token
      end

    assert Enum.sort(seen) == Enum.sort([fresh_token | tokens])
    for {job, _, _} <- waiting, do: wait_state(job.id, :completed)
    wait_state(fresh.id, :completed)
  end
end
