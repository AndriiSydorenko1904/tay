defmodule Tay.Execution.ModelTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.NativeHelpers
  @moduletag capture_log: true
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    :ok
  end

  property "generated live/crash/manual-cycle histories match replay and an independent attempt oracle" do
    check all(
            maximum <- integer(1..3),
            program <-
              list_of(tuple({member_of([:failure, :timeout, :interrupt]), boolean()}),
                max_length: 4
              ),
            max_runs: 20
          ) do
      H.set_clock(1_000_000, 0)
      path = NativeHelpers.path()
      H.initialize(path)
      {:ok, root} = H.start(path, @name)
      Process.put(:model_root, root)

      try do
        {job, token} = H.job(max_attempts: maximum, timeout_ms: 100)
        assert {:ok, _} = Tay.insert(job, name: @name)

        {root, ordinal, ordinals, outcomes} =
          Enum.reduce(program, {root, 1, [], []}, fn {action, expedite},
                                                     {root, ordinal, ordinals, outcomes} ->
            {task, entered} = H.await_entry(token)
            assert entered.attempt == ordinal

            {root, settled, outcome} =
              case action do
                :interrupt ->
                  Process.exit(H.engine(root), :kill)
                  assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
                  assert H.eventually(fn -> not Process.alive?(task) end)
                  H.stop(root)
                  {:ok, next} = H.start(path, @name)
                  Process.put(:model_root, next)
                  {next, H.await_job(@name, job.id, :retryable), 3}

                :failure ->
                  send(task, {:return, {:error, :bounded_class_only}})
                  state = if ordinal == maximum, do: :discarded, else: :retryable
                  {root, H.await_job(@name, job.id, state), 1}

                :timeout ->
                  {relay, entry} = H.runtime_entry(root, job.id)
                  H.set_clock(H.clock(:wall), H.clock(:monotonic) + 100)
                  send(relay, {:timeout, entry.ticket})
                  state = if ordinal == maximum, do: :discarded, else: :retryable
                  {root, H.await_job(@name, job.id, state), 2}
              end

            assert H.eventually(fn -> not Process.alive?(task) end)

            next_ordinal =
              cond do
                action == :interrupt -> ordinal
                ordinal == maximum -> 1
                true -> ordinal + 1
              end

            if settled.state == :discarded or expedite do
              assert {:ok, _} =
                       Tay.retry(job.id, name: @name, expected_revision: settled.revision)
            else
              due = H.due(settled)
              H.tick(root, due - 1)
              refute_receive {:tay_test_entered, ^token, _, _}, 5
              H.tick(root, due)
            end

            {root, next_ordinal, ordinals ++ [ordinal], outcomes ++ [outcome]}
          end)

        {task, entered} = H.await_entry(token)
        assert entered.attempt == ordinal
        send(task, {:return, :ok})
        live = H.await_job(@name, job.id, :completed)
        assert H.eventually(fn -> Tay.status(name: @name).running_executions == 0 end)
        H.stop(root)
        history = H.history(path)
        starts = Enum.filter(history, &(&1.event.record_type == 3))
        finishes = Enum.filter(history, &(&1.event.record_type == 4))
        assert Enum.map(starts, & &1.event.data["attempt"]) == ordinals ++ [ordinal]
        assert Enum.map(finishes, & &1.event.data["outcome"]) == outcomes ++ [0]
        sequences = Enum.map(starts, & &1.sequence)
        assert sequences == Enum.sort(Enum.uniq(sequences))
        assert H.entries(token) == length(program) + 1
        {:ok, raw} = Tay.JobID.decode(job.id)
        recovered = H.replay(path).jobs[raw]
        assert recovered.state == live.state
        assert recovered.attempt == live.attempt
        assert recovered.definition == live.definition
        assert recovered.diagnostic == List.first(live.errors)
        assert elem(live.revision, 4) == recovered.revision
      after
        H.stop(Process.get(:model_root))
        File.rm_rf!(path)
      end
    end
  end

  test "a manually expedited timeout cannot overlap its still-alive callback despite another free slot" do
    path = NativeHelpers.path()
    H.initialize(path)
    parent = self()

    delayed = fn task ->
      send(parent, {:termination_requested, task})
      :ok
    end

    {:ok, root} = H.start(path, @name, queues: [default: 2], test_terminate: delayed)

    on_exit(fn ->
      H.stop(root)
      File.rm_rf!(path)
    end)

    {job, token} = H.job(max_attempts: 2, timeout_ms: 100)
    assert {:ok, _} = Tay.insert(job, name: @name)
    {first, _} = H.await_entry(token)
    {relay, entry} = H.runtime_entry(root, job.id)
    H.set_clock(H.clock(:wall), 100)
    send(relay, {:timeout, entry.ticket})
    retryable = H.await_job(@name, job.id, :retryable)
    assert_receive {:termination_requested, ^first}
    assert Process.alive?(first)

    assert {:ok, available} =
             Tay.retry(job.id, name: @name, expected_revision: retryable.revision)

    assert available.state == :available
    H.wake(root)
    refute_receive {:tay_test_entered, ^token, _, _}, 40
    assert H.entries(token) == 1
    assert Tay.status(name: @name).queue_slots_used["default"] == 1
    {other, other_token} = H.job()
    assert {:ok, _} = Tay.insert(other, name: @name)
    {other_task, _} = H.await_entry(other_token)
    assert Process.alive?(first)
    send(other_task, {:return, :ok})
    H.await_job(@name, other.id, :completed)
    Process.exit(first, :kill)
    {second, entered} = H.await_entry(token)
    refute Process.alive?(first)
    assert entered.attempt == 2
    refute first == second
    send(second, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    H.stop(root)

    starts =
      Enum.filter(
        H.history(path),
        &(&1.event.record_type == 3 and
            &1.event.data["job_id"] == elem(Tay.JobID.decode(job.id), 1))
      )

    assert length(starts) == 2
  end

  test "executing cancellation retains queue credit until delayed termination is confirmed" do
    path = NativeHelpers.path()
    H.initialize(path)
    parent = self()

    {:ok, root} =
      H.start(path, @name,
        test_terminate: fn task ->
          send(parent, {:terminate, task})
          :ok
        end
      )

    on_exit(fn ->
      H.stop(root)
      File.rm_rf!(path)
    end)

    {first, token} = H.job()
    {second, second_token} = H.job()
    assert {:ok, _} = Tay.insert(first, name: @name)
    {task, entered} = H.await_entry(token)
    assert {:ok, _} = Tay.insert(second, name: @name)

    assert {:ok, %{state: :cancelled}} =
             Tay.cancel(first.id, name: @name, expected_revision: entered.revision)

    assert_receive {:terminate, ^task}
    assert Process.alive?(task)
    H.wake(root)
    refute_receive {:tay_test_entered, ^second_token, _, _}, 40
    assert Tay.status(name: @name).queue_slots_used["default"] == 1
    Process.exit(task, :kill)
    {next, _} = H.await_entry(second_token)
    send(next, {:return, :ok})
    H.await_job(@name, second.id, :completed)
    assert H.await_job(@name, first.id, :cancelled).attempt == 1
    H.stop(root)
  end
end
