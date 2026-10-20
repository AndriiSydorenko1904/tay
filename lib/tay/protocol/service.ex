defmodule Tay.Protocol.Service do
  @moduledoc false

  alias Tay.Core.API
  alias Tay.Protocol.JobOptions
  alias Tay.Schedule.API, as: ScheduleAPI

  @type context :: %{
          optional(:core) => {module(), term()},
          optional(:engine) => atom(),
          optional(:schedule) => {module(), term()},
          optional(:executor) => GenServer.server() | nil
        }
  @type response ::
          {:ok, String.t(), map()}
          | {:error, String.t()}
          | {:error, String.t(), map()}

  @spec handle(context(), map()) :: response()
  def handle(context, %{"type" => type} = message) when is_map(context) do
    core = core(context)
    schedule = schedule(context)

    case type do
      "enqueue" -> enqueue(core, message)
      "status" -> status(core, message)
      "cancel" -> cancel_job(core, message)
      "result" -> result(core, message)
      "schedule" -> schedule(schedule, message)
      "cancel_schedule" -> cancel_schedule(schedule, message)
      _ -> {:error, "unsupported_request"}
    end
  catch
    :exit, _ ->
      {:error, "unavailable"}

    _, _ ->
      {:error, "invalid_request"}
  end

  def handle(_, _), do: {:error, "invalid_request"}

  defp enqueue(core, %{"task" => task, "args" => args} = message) do
    with {:ok, options} <- JobOptions.parse(Map.get(message, "options", %{})),
         {:ok, job} <- API.call(core, :enqueue, [task, args, options]) do
      {:ok, "enqueued", %{"job_id" => job.id, "job" => public_job(job)}}
    else
      {:error, %Tay.Error{kind: :unknown_outcome, reason: reason}} ->
        {:error, "unknown_outcome", %{"reason" => unknown_outcome_reason(reason)}}

      {:error, %Tay.Error{kind: :capacity, reason: reason}} ->
        {:error, "capacity", %{"reason" => capacity_reason(reason)}}

      {:error, %Tay.Error{kind: :unavailable}} ->
        {:error, "unavailable"}

      {:error, _} ->
        {:error, "invalid_enqueue"}

      _ ->
        {:error, "invalid_enqueue"}
    end
  end

  defp status(core, %{"job_id" => id}) do
    case API.call(core, :get_job, [id]) do
      {:ok, job} ->
        {:ok, "status", %{"job" => public_job(job), "status" => Atom.to_string(job.state)}}

      {:error, :not_found} ->
        {:error, "not_found"}

      _ ->
        {:error, "unavailable"}
    end
  end

  defp status(_, _), do: {:error, "invalid_request"}

  defp cancel_job(core, %{"job_id" => id}) do
    case API.call(core, :cancel, [id]) do
      {:ok, job} ->
        {:ok, "cancelled", %{"job" => public_job(job), "status" => Atom.to_string(job.state)}}

      {:error, :not_found} ->
        {:error, "not_found"}

      {:error, _} ->
        {:error, "cancel_rejected"}
    end
  end

  defp cancel_job(_, _), do: {:error, "invalid_request"}

  defp result(core, %{"job_id" => id}) do
    case API.call(core, :get_job, [id]) do
      {:ok, %{state: :completed}} ->
        case API.call(core, :result, [id]) do
          {:ok, value} -> {:ok, "result", %{"result" => value}}
          :missing -> {:ok, "result", %{"result" => nil}}
          _ -> {:ok, "result", %{"result" => nil}}
        end

      {:ok, %{state: :discarded}} ->
        {:error, "task_failed"}

      {:ok, _} ->
        {:error, "result_not_ready"}

      {:error, :not_found} ->
        {:error, "not_found"}

      _ ->
        {:error, "unavailable"}
    end
  end

  defp result(_, _), do: {:error, "invalid_request"}

  defp schedule(executor, message) do
    fields = Map.drop(message, ["version", "type", "request_id"])

    case ScheduleAPI.call(executor, :register, [fields]) do
      {:ok, value} ->
        {:ok, "scheduled", %{"schedule_id" => value["id"], "schedule" => value}}

      {:error, code} ->
        {:error, code}

      {:error, code, fields} ->
        {:error, code, fields}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, "unknown_outcome", %{"reason" => "caller_timeout_or_disconnect"}}
  end

  defp cancel_schedule(executor, %{"schedule_id" => id}) when is_binary(id) do
    case ScheduleAPI.call(executor, :cancel, [id]) do
      {:ok, value} ->
        {:ok, "schedule_cancelled", %{"schedule_id" => id, "schedule" => value}}

      {:error, code} ->
        {:error, code}

      {:error, code, fields} ->
        {:error, code, fields}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, "unknown_outcome", %{"reason" => "caller_timeout_or_disconnect"}}
  end

  defp cancel_schedule(_, _), do: {:error, "invalid_schedule_id"}

  defp core(%{core: {adapter, _target} = core}) when is_atom(adapter), do: core
  defp core(%{engine: engine}) when is_atom(engine), do: {Tay.Core.Local, engine}
  defp core(_), do: raise(ArgumentError, "invalid core adapter")

  defp schedule(%{schedule: {adapter, _target} = schedule}) when is_atom(adapter), do: schedule

  defp schedule(%{executor: executor}) when is_pid(executor),
    do: {Tay.Schedule.ViaExecutor, executor}

  defp schedule(_), do: {Tay.Schedule.Local, nil}

  defp capacity_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp capacity_reason(_), do: "capacity_exhausted"

  defp unknown_outcome_reason(:submitted_request_lost), do: "caller_timeout_or_disconnect"
  defp unknown_outcome_reason({:generation_lost, _component}), do: "generation_lost"
  defp unknown_outcome_reason(_), do: "outcome_unknown"

  defp public_job(job) do
    %{
      "id" => job.id,
      "task" => job.worker_key,
      "args" => job.args,
      "state" => Atom.to_string(job.state),
      "attempt" => job.attempt,
      "max_attempts" => job.max_attempts,
      "queue" => to_string(job.queue),
      "durability" => Atom.to_string(job.durability),
      "scheduled_at" => present_time(job.scheduled_at),
      "completed_at" => present_time(job.completed_at),
      "errors" => job.errors
    }
  end

  defp present_time(nil), do: nil
  defp present_time(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp present_time(value), do: value
end
