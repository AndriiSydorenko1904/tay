defmodule Tay.Engine.Execution do
  @moduledoc """
  Execution transitions evaluated by the Engine process itself.
  This module never owns indexes or introduces an additional process: commits,
  relay release, and settlement retain their original serialization order.
  """
  alias Tay.Event
  alias Tay.Engine.{Persistence, ProjectionState}
  alias Tay.Execution.{Clock, ControlPlane, Dispatcher, Outcome, Relay}
  alias Tay.Gateway.Runtime, as: GatewayRuntime
  alias Tay.State.{JobIndex, Projection, SchedulerIndex, TaskIndex}
  alias Tay.Storage.V2.{Codec, Mutation}
  alias Tay.Storage.V2.Reducer, as: V2Reducer

  def reconcile(s) do
    match = [{{:"$1", %{state: :executing}}, [], [true]}]
    count = :ets.select_count(s.projection.jobs, match)
    s = %{s | settlement_reserve: count, persistent_settlement_reserve: count}
    :ok = GenServer.call(s.guardian, {:reconciliation, ProjectionState.snapshot(s)})

    selection =
      :ets.select(
        s.projection.jobs,
        [{{:"$1", %{state: :executing}}, [], [:"$1"]}],
        s.config.execution_batch
      )

    reconcile_batch(s, selection)
  end

  defp reconcile_batch(s, :"$end_of_table"), do: s

  defp reconcile_batch(s, {ids, continuation}) do
    s =
      Enum.reduce(ids, s, fn id, acc ->
        job = JobIndex.get(acc.projection.jobs, id)
        {:ok, event} = Outcome.event(job, :interrupted, Clock.wall(acc.config.clock))

        case Persistence.commit(acc, job, event) do
          {:ok, _, next} -> next
          _ -> exit(:interrupted_settlement_failed)
        end
      end)

    hook(s.config, :reconciliation_batch)
    :ok = GenServer.call(s.guardian, {:reconciliation, ProjectionState.snapshot(s)})
    reconcile_batch(s, :ets.select(continuation))
  end

  def start_controls(s) do
    components = Tay.Execution.Supervisor.components(s.runtime)

    with {:ok, controls} <-
           ControlPlane.start(components.controls, self(), s.generation, s.config),
         {:ok, executor_server} <-
           GatewayRuntime.start(components.gateways, self(), s.config, %{schedules: s.schedules}) do
      %{s | controls: controls, executor_server: executor_server}
    else
      {:error, reason} -> exit({:control_plane_start_failed, reason})
    end
  end

  def control_member?(s, kind, pid) do
    valid_control_kind?(s, kind) and
      (Map.get(s.controls, kind) == pid or
         Enum.any?(
           DynamicSupervisor.which_children(
             Tay.Execution.Supervisor.components(s.runtime).controls
           ),
           fn {_, child, _, _} -> child == pid end
         ))
  end

  defp valid_control_kind?(_s, :scheduler), do: true

  defp valid_control_kind?(s, {:queue, queue}),
    do: Map.has_key?(s.config.queue_limits, queue)

  defp valid_control_kind?(_s, _kind), do: false

  def control(_kind, %{mode: mode} = s) when mode != :ready,
    do: {s, s.config.execution_wake_ms}

  def control(:scheduler, s) do
    at = Clock.wall(s.config.clock)
    ids = SchedulerIndex.due(s.projection.schedule, at, s.config.execution_batch)

    {s, refused} =
      Enum.reduce_while(ids, {s, false}, fn id, {acc, _} ->
        job = JobIndex.get(acc.projection.jobs, id)
        at = Clock.wall(acc.config.clock)

        if job.eligible_at <= at do
          case Persistence.commit(acc, job, event(2, job, at, %{"due_at" => job.eligible_at})) do
            {:ok, _, next} -> {:cont, {next, false}}
            {:error, _} -> {:halt, {acc, true}}
          end
        else
          {:halt, {acc, false}}
        end
      end)

    due = SchedulerIndex.earliest(s.projection.schedule)
    # A capacity refusal must not turn a due head into a busy loop.
    delay =
      if due && not refused,
        do: Clock.delay_until(due, Clock.wall(s.config.clock), s.config.execution_wake_ms),
        else: s.config.execution_wake_ms

    {wake_queues(s), delay}
  end

  def control({:queue, queue}, s) do
    if not MapSet.member?(s.paused, queue) and s.slots[queue] < s.config.queue_limits[queue] do
      case next_ready(s, queue, Clock.wall(s.config.clock)) do
        {:ok, job} ->
          case claim(s, job, queue) do
            {:ok, next} -> {next, 0}
            {:error, next} -> {next, s.config.execution_wake_ms}
          end

        :none ->
          {s, s.config.execution_wake_ms}
      end
    else
      {s, s.config.execution_wake_ms}
    end
  end

  # Pick the oldest ready job *among capabilities with current capacity*.
  # Querying the task index per advertised capability is bounded by the server
  # connection/task limits, and means an absent PHP executor cannot hide a
  # later Python task at the head of a shared queue.
  defp next_ready(s, queue, now) do
    local = Map.keys(s.projection.registry)

    external = Dispatcher.available_tasks(s.executor_server)

    candidates =
      (local ++ external)
      |> Enum.uniq()
      |> Enum.filter(
        &Tay.Execution.RateLimiter.allowed?(
          s.rate_limiter,
          queue,
          &1,
          Clock.monotonic(s.config.clock)
        )
      )
      |> Enum.flat_map(fn task ->
        case TaskIndex.ready(s.projection.task, queue, task, now, 1) do
          [id] ->
            case JobIndex.get(s.projection.jobs, id) do
              nil -> []
              job -> [job]
            end

          [] ->
            []
        end
      end)

    case candidates do
      [] -> :none
      jobs -> {:ok, Enum.min_by(jobs, &TaskIndex.key/1)}
    end
  catch
    :exit, _ -> :none
  end

  defp claim(s, job, queue) do
    at = Clock.wall(s.config.clock)
    started = event(3, job, at, %{"attempt" => job.next_attempt, "cycle_token" => job.cycle})

    with {:ok, dispatch} <- dispatch_for(s, job),
         true <- not MapSet.member?(s.projection.held, job.id),
         {:ok, predicted} <- predict_execution(s, job, started),
         :ok <- settlement_fits(s, predicted, at),
         {:ok, {_, _, payload}} <- execution_encoding(s, job, started),
         :ok <- execution_headroom(s, job, payload) do
      case dispatch do
        {:local, worker} ->
          options = %{
            engine: self(),
            guardian: s.guardian,
            generation: s.generation,
            worker: worker,
            timeout_ms: job.definition["timeout_ms"],
            clock: s.config.clock,
            eligible_at: job.eligible_at,
            test_terminate: test_terminate_option(s.config)
          }

          case Tay.Execution.Supervisor.prepare(s.runtime, options) do
            {:ok, identity} -> start_waiting(s, job, queue, identity)
            _ -> exit(:execution_start_failed)
          end

        {:external, server, reservation} ->
          Dispatcher.start_external(s, job, queue, started, server, reservation)
      end
    else
      _ -> {:error, s}
    end
  end

  defp execution_headroom(s, job, payload) do
    if ProjectionState.durability(s, job) == :persistent,
      do: Persistence.headroom(s, byte_size(payload), s.persistent_settlement_reserve + 1),
      else: :ok
  end

  defp dispatch_for(s, job) do
    Dispatcher.select(
      s.config.workers,
      s.executor_server,
      job.definition["worker_key"],
      job.definition["queue_key"]
    )
  end

  defp settlement_fits(s, executing, at) do
    Enum.reduce_while([:success, {:failure, 1}, :timeout, :interrupted], :ok, fn outcome, _ ->
      with {:ok, finished} <- Outcome.event(executing, outcome, at, fn 2 -> <<0, 0>> end),
           {:ok, _} <- execution_encoding(s, executing, finished),
           {:ok, _} <- prepare_settlement(s, executing, finished) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :settlement_budget}}
      end
    end)
  end

  defp predict_execution(s, job, event), do: prepare_settlement(s, job, event)

  defp execution_encoding(s, job, event) do
    with {:ok, mutation} <- Mutation.from_event(event, job, s.next_availability_order),
         {:ok, payload} <- Codec.encode_mutation(mutation, s.config.value_limits),
         do: {:ok, {8, 1, payload}}
  end

  defp prepare_settlement(s, job, event) do
    with {:ok, mutation} <- Mutation.from_event(event, job, s.next_availability_order),
         {:ok, predicted, _} <-
           V2Reducer.apply_one(
             job,
             mutation,
             s.next_availability_order,
             s.config.candidate_limits,
             s.config.value_limits
           ),
         do: {:ok, predicted}
  end

  defp start_waiting(s, job, queue, identity) do
    monitor = Process.monitor(identity.relay)

    entry =
      Map.merge(identity, %{
        id: job.id,
        schedule_id: Map.get(s.schedule_owners, job.id),
        queue: queue,
        eligible_at: job.eligible_at,
        execution: nil,
        released: false,
        settled: false,
        dead: false,
        monitor: monitor
      })

    s = %{
      s
      | running: Map.put(s.running, identity.relay, entry),
        executions: Map.put(s.executions, job.id, identity.relay),
        relay_monitors: Map.put(s.relay_monitors, monitor, identity.relay),
        slots: Map.update!(s.slots, queue, &(&1 + 1)),
        projection: Projection.hold(s.projection, job)
    }

    hook(s.config, {:execution, :task_waiting})
    at = Clock.wall(s.config.clock)

    if Process.alive?(identity.task) and at >= job.eligible_at do
      started = event(3, job, at, %{"attempt" => job.next_attempt, "cycle_token" => job.cycle})

      case Persistence.commit(s, job, started) do
        {:ok, executing, next} ->
          entry = %{entry | execution: executing.execution}
          next = %{next | running: Map.put(next.running, identity.relay, entry)}
          {:ok, release_pending(next)}

        {:error, _} ->
          {:error, abandon_waiting(s, identity.relay)}
      end
    else
      {:error, abandon_waiting(s, identity.relay)}
    end
  end

  defp abandon_waiting(s, relay) do
    entry = s.running[relay]
    :ok = Relay.terminate_task(relay, entry.ticket)
    %{s | running: Map.put(s.running, relay, %{entry | settled: true})}
  end

  def release_pending(s) do
    Enum.reduce(s.running, s, fn {relay, entry}, acc ->
      if (Map.get(entry, :kind) != :external and
            (not entry.released and not entry.settled and entry.execution)) &&
           Clock.wall(acc.config.clock) >= entry.eligible_at do
        hook(acc.config, {:execution, :pre_release})
        # Recheck after a fault barrier as well as after storage latency.
        if Clock.wall(acc.config.clock) >= entry.eligible_at do
          job = JobIndex.get(acc.projection.jobs, entry.id)

          case Relay.release(relay, entry.ticket, entry.execution, ProjectionState.view(acc, job)) do
            :ok ->
              hook(acc.config, {:execution, :released})
              %{acc | running: Map.put(acc.running, relay, %{entry | released: true})}

            _ ->
              exit(:execution_release_failed)
          end
        else
          acc
        end
      else
        acc
      end
    end)
  end

  def execution_message(s, relay, entry, {:outcome, outcome}) do
    job = JobIndex.get(s.projection.jobs, entry.id)

    if not entry.settled and entry.released and job.state == :executing and
         job.execution == entry.execution and job.revision == entry.execution do
      {:ok, finished} = Outcome.event(job, outcome, Clock.wall(s.config.clock))

      case Persistence.commit(s, job, finished) do
        {:ok, _, next} ->
          :ok = Relay.settled(relay, entry.ticket)

          finish_runtime(
            %{next | running: Map.put(next.running, relay, %{entry | settled: true})},
            relay
          )

        _ ->
          exit(:execution_settlement_failed)
      end
    else
      s
    end
  end

  def execution_message(s, relay, entry, :dead) do
    hook(s.config, {:execution, :task_dead})

    if entry.execution != nil and not entry.released and not entry.settled,
      do: exit(:execution_release_failed)

    finish_runtime(%{s | running: Map.put(s.running, relay, %{entry | dead: true})}, relay)
  end

  def execution_message(s, _relay, _entry, _), do: s

  def cancel_task(s, id) do
    case Map.get(s.executions, id) do
      nil ->
        s

      {:executor, reservation} = key ->
        case Map.get(s.running, key) do
          %{kind: :external} = entry ->
            if is_pid(entry.server), do: Dispatcher.cancel(entry.server, reservation)
            Dispatcher.settle(s, key, entry, :cancelled)

          _ ->
            s
        end

      relay ->
        entry = s.running[relay]
        :ok = Relay.terminate_task(relay, entry.ticket)
        finish_runtime(%{s | running: Map.put(s.running, relay, %{entry | settled: true})}, relay)
    end
  end

  defp finish_runtime(s, relay) do
    case s.running[relay] do
      %{settled: true, dead: true} = entry ->
        Process.demonitor(entry.monitor, [:flush])
        job = JobIndex.get(s.projection.jobs, entry.id)

        %{
          s
          | running: Map.delete(s.running, relay),
            executions: Map.delete(s.executions, entry.id),
            relay_monitors: Map.delete(s.relay_monitors, entry.monitor),
            slots: Map.update!(s.slots, entry.queue, &(&1 - 1)),
            projection: Projection.release(s.projection, job, entry.id)
        }

      _ ->
        s
    end
  end

  def wake_controls(s) do
    Enum.reduce(s.controls, s, fn {kind, pid}, acc -> wake_control(acc, kind, pid) end)
  end

  def wake_queues(s) do
    Enum.reduce(s.controls, s, fn
      {{:queue, _} = kind, pid}, acc -> wake_control(acc, kind, pid)
      _, acc -> acc
    end)
  end

  defp wake_control(s, kind, pid) do
    if MapSet.member?(s.control_wakes, kind) do
      s
    else
      Tay.Execution.Queue.wake(pid)
      %{s | control_wakes: MapSet.put(s.control_wakes, kind)}
    end
  end

  defp event(type, job, at, fields),
    do: %Event{
      record_type: type,
      data:
        Map.merge(%{"job_id" => job.id, "expected_revision" => job.revision, "at" => at}, fields)
    }

  if Mix.env() == :test do
    defp test_terminate_option(config), do: Map.get(config, :test_terminate)

    defp hook(config, point) do
      if is_function(Map.get(config, :test_hook), 1), do: config.test_hook.(point)
      :ok
    end
  else
    defp test_terminate_option(_config), do: nil
    defp hook(_config, _point), do: :ok
  end
end
