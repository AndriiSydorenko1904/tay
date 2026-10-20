defmodule Tay.Execution.Dispatcher do
  @moduledoc false

  alias Tay.Event
  alias Tay.Engine.{Persistence, ProjectionState}
  alias Tay.Execution.{Clock, Outcome, Registry}
  alias Tay.Executor.Server
  alias Tay.State.{JobIndex, Projection}

  def available_tasks(nil), do: []

  def available_tasks(server) when is_pid(server) do
    if Process.alive?(server), do: Server.available_tasks(server), else: []
  catch
    :exit, _ -> []
  end

  def select(workers, server, worker_key, queue_key) do
    case Registry.resolve(workers, worker_key) do
      {:ok, worker} ->
        {:ok, {:local, worker}}

      _ when is_pid(server) ->
        case Server.reserve(server, worker_key, queue_key) do
          {:ok, reservation} -> {:ok, {:external, server, reservation}}
          _ -> {:error, :no_executor_capacity}
        end

      _ ->
        {:error, :unavailable_worker}
    end
  catch
    :exit, _ -> {:error, :no_executor_capacity}
  end

  def dispatch(server, reservation, job),
    do: safe(fn -> Server.dispatch(server, reservation, job) end)

  def release(server, reservation), do: safe(fn -> Server.release(server, reservation) end, :ok)
  def cancel(server, reservation), do: safe(fn -> Server.cancel(server, reservation) end, :ok)

  def outcome(:success), do: :success
  def outcome({:success, _result}), do: :success
  def outcome(:timeout), do: :timeout
  def outcome(:lost), do: :interrupted
  def outcome({:failure, _}), do: {:failure, 1}
  def outcome(_), do: {:failure, 1}

  def start_external(state, job, queue, started, server, reservation) do
    case Persistence.commit(state, job, started) do
      {:ok, executing, next} ->
        key = {:executor, reservation}

        timer =
          Process.send_after(
            self(),
            {:executor_timeout, reservation, executing.execution},
            job.definition["timeout_ms"]
          )

        entry = %{
          kind: :external,
          id: job.id,
          queue: queue,
          execution: executing.execution,
          reservation: reservation,
          server: server,
          timer: timer
        }

        next = %{
          next
          | running: Map.put(next.running, key, entry),
            executions: Map.put(next.executions, job.id, key),
            slots: Map.update!(next.slots, queue, &(&1 + 1)),
            projection: Projection.hold(next.projection, job)
        }

        case dispatch(server, reservation, ProjectionState.view(next, executing)) do
          :ok -> {:ok, next}
          _ -> {:error, settle(next, key, entry, :lost)}
        end

      {:error, _} ->
        release(server, reservation)
        {:error, state}
    end
  end

  def settle(state, key, entry, result) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    job = JobIndex.get(state.projection.jobs, entry.id)

    state =
      case {result, job} do
        {:cancelled, _} ->
          state

        {_, %{state: :executing, execution: execution}} when execution == entry.execution ->
          settle_job(state, job, result)

        _ ->
          state
      end

    if is_pid(entry.server), do: release(entry.server, entry.reservation)

    %{
      state
      | running: Map.delete(state.running, key),
        executions: Map.delete(state.executions, entry.id),
        slots: Map.update!(state.slots, entry.queue, &max(&1 - 1, 0)),
        projection: if(job, do: Projection.release(state.projection, job), else: state.projection)
    }
  end

  defp settle_job(state, job, result) do
    case Outcome.event(job, outcome(result), Clock.wall(state.config.clock)) do
      {:ok, finished} ->
        case Persistence.commit(state, job, finished) do
          {:ok, completed, next} -> persist_result(next, completed, result)
          _ -> exit(:external_execution_settlement_failed)
        end

      _ ->
        exit(:external_execution_outcome_invalid)
    end
  end

  defp persist_result(state, completed, {:success, result}) do
    event = %Event{
      record_type: 10,
      payload_schema_version: 2,
      data: %{
        "at" => completed.completed_at,
        "expected_revision" => completed.revision,
        "job_id" => completed.id,
        "result" => result
      }
    }

    case Persistence.commit_auxiliary(state, event, completed) do
      {:ok, next} -> next
      _ -> exit(:external_result_commit_failed)
    end
  end

  defp persist_result(state, _completed, _result), do: state

  defp safe(function, fallback \\ {:error, :executor_unavailable}) do
    function.()
  catch
    :exit, _ -> fallback
  end
end
