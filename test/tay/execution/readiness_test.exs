defmodule Tay.Execution.ReadinessTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Tay.Execution.LocalFence
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.NativeHelpers
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    path = H.initialize(NativeHelpers.path())
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start_async(path, options) do
    parent = self()
    ref = make_ref()

    creator =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        result = H.start(path, @name, options)
        send(parent, {:startup_result, ref, result})

        # Keep a successful, unexpectedly early result alive long enough for
        # the assertion to diagnose it, rather than losing its linked root.
        receive do
          :finish -> if match?({:ok, _}, result), do: H.stop(elem(result, 1))
        end
      end)

    on_exit(fn -> if Process.alive?(creator), do: send(creator, :finish) end)
    {creator, ref}
  end

  defp barrier(parent, target) do
    fn point ->
      if point == target do
        send(parent, {:readiness_boundary, point, self()})

        receive do
          :continue -> :ok
        end
      end
    end
  end

  for component <- [:runtime, :fence] do
    @component component
    test "#{component} loss already queued behind readiness cannot open the admission gate", %{
      path: path
    } do
      before = R.snapshot(path)
      {creator, ref} = start_async(path, test_hook: barrier(self(), :pre_ready))
      assert_receive {:readiness_boundary, :pre_ready, engine}, 5_000
      guardian = Process.whereis(@name)
      state = :sys.get_state(guardian)
      :ok = :sys.suspend(guardian)

      try do
        send(engine, :continue)

        # Force the adverse signal order: ready is already queued before the
        # component's DOWN. Readiness must inspect current fence health, not
        # depend on processing that later monitor notification first.
        assert H.eventually(fn ->
                 {:messages, messages} = Process.info(guardian, :messages)

                 Enum.any?(messages, fn
                   {:"$gen_call", _, {:ready, _}} -> true
                   _ -> false
                 end)
               end)

        target = if @component == :fence, do: LocalFence.guard(state.fence), else: state.runtime
        monitor = Process.monitor(target)
        Process.exit(target, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^target, :killed}, 5_000
      after
        if Process.alive?(guardian), do: :sys.resume(guardian)
      end

      assert_receive {:startup_result, ^ref, {:error, _}}, 5_000
      send(creator, :finish)
      assert Tay.status(name: @name).state == :unavailable
      assert R.snapshot(path) == before
      assert H.history(path) == []

      if @component == :fence do
        assert {:error, _} = H.start(path, @name)
        assert R.snapshot(path) == before
      else
        assert {:ok, next} = H.start(path, @name)
        assert Tay.status(name: @name).state == :ready
        H.stop(next)
      end
    end
  end

  test "crash after one reconciliation batch commits only that subset and resumes without attempt loss",
       %{path: path} do
    assert {:ok, root} = H.start(path, @name, queues: [default: 5])
    on_exit(fn -> H.stop(root) end)

    jobs =
      for _ <- 1..5 do
        {job, token} = H.job(max_attempts: 1)
        assert {:ok, _} = Tay.insert(job, name: @name)
        {task, metadata} = H.await_entry(token)
        {job, token, task, metadata}
      end

    Process.exit(H.engine(root), :kill)
    assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)

    assert H.eventually(fn ->
             Enum.all?(jobs, fn {_, _, task, _} -> not Process.alive?(task) end)
           end)

    H.stop(root)
    assert length(H.history(path)) == 10

    {creator, ref} =
      start_async(path,
        queues: [default: 5],
        execution_batch: 1,
        test_hook: barrier(self(), :reconciliation_batch)
      )

    assert_receive {:readiness_boundary, :reconciliation_batch, engine}, 5_000

    assert %{state: :recovering, phase: :reconciling, pending_reconciliation: pending} =
             Tay.status(name: @name)

    assert pending > 0

    for {job, token, _, _} <- jobs do
      assert {:error, %{kind: :unavailable}} = Tay.get_job(job.id, name: @name)
      assert H.entries(token) == 1
    end

    Process.exit(engine, :kill)
    assert_receive {:startup_result, ^ref, {:error, _}}, 5_000
    send(creator, :finish)
    partial = H.history(path)
    finishes = Enum.filter(partial, &(&1.event.record_type == 4))
    assert length(partial) == 11 and length(finishes) == 1
    assert hd(finishes).event.data["outcome"] == 3
    assert hd(finishes).event.data["next_attempt"] == 1

    # Missing current worker mappings must not affect reconciliation of persisted
    # execution semantics or consume a logical failure attempt.
    assert {:ok, recovered} =
             H.start(path, @name, workers: %{}, queues: [default: 5], execution_batch: 1)

    on_exit(fn -> H.stop(recovered) end)
    assert %{state: :ready, unsettled_executions: 0, blocked_jobs: 5} = Tay.status(name: @name)

    due =
      for {job, token, _, _} <- jobs do
        retryable = H.await_job(@name, job.id, :retryable)
        assert retryable.attempt == 1 and retryable.worker == nil
        assert retryable.errors == [%{"code" => 7, "version" => 1}]
        assert H.entries(token) == 1
        H.due(retryable)
      end

    H.stop(recovered)
    history = H.history(path)
    finishes = Enum.filter(history, &(&1.event.record_type == 4))
    assert length(finishes) == 5

    assert Enum.frequencies_by(finishes, & &1.event.data["job_id"]) |> Map.values() == [
             1,
             1,
             1,
             1,
             1
           ]

    assert Enum.all?(
             finishes,
             &(&1.event.data["outcome"] == 3 and &1.event.data["next_attempt"] == 1)
           )

    assert {:ok, restored} = H.start(path, @name, queues: [default: 5], execution_batch: 1)
    on_exit(fn -> H.stop(restored) end)
    H.tick(restored, Enum.max(due))

    for {job, token, old_task, old_metadata} <- jobs do
      {task, metadata} = H.await_entry(token)
      assert metadata.attempt == 1
      assert elem(metadata.revision, 4) > elem(old_metadata.revision, 4)
      refute Process.alive?(old_task)
      send(task, {:return, :ok})
      H.await_job(@name, job.id, :completed)
      assert H.entries(token) == 2
    end

    H.stop(restored)

    assert Enum.count(
             H.history(path),
             &(&1.event.record_type == 4 and &1.event.data["outcome"] == 3)
           ) == 5
  end
end
