defmodule Tay.Executor.Job do
  @moduledoc false

  alias Tay.{Error, Job, JobID}
  alias Tay.Event.V1

  @options [:id, :queue, :retries, :timeout_ms, :delay_ms, :scheduled_at]

  # Builds the existing immutable Event-v1 definition.  The remote marker is
  # checked again by the Engine; this helper merely keeps all producer paths
  # on the same canonical job/ID reconciliation model.
  def new(task, args, options \\ []) do
    with true <- V1.key?(task) || {:error, :invalid_task},
         true <- (is_map(args) and not is_struct(args)) || {:error, :invalid_args},
         true <- valid_options?(options) || {:error, :invalid_options},
         {:ok, max_attempts} <- attempts(Keyword.get(options, :retries, 0)),
         {:ok, scheduled_at} <- schedule(options),
         id <- Keyword.get_lazy(options, :id, &JobID.new/0),
         {:ok, job} <-
           Job.new(Tay.Executor.RemoteWorker, args,
             id: id,
             worker_key: task,
             queue: Keyword.get(options, :queue, :default),
             max_attempts: max_attempts,
             timeout_ms: Keyword.get(options, :timeout_ms, 30_000),
             scheduled_at: scheduled_at
           ) do
      {:ok, job}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:invalid, reason)}
    end
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(Keyword.keys(options), &(&1 in @options))
  end

  # Tay's Event-v1 maximum is the number of executions, whereas the public
  # protocol calls this number retries after the initial execution.
  defp attempts(retries) when is_integer(retries) and retries in 0..65_534,
    do: {:ok, retries + 1}

  defp attempts(_), do: {:error, :invalid_retries}

  defp schedule(options) do
    case {Keyword.get(options, :scheduled_at), Keyword.get(options, :delay_ms)} do
      {nil, nil} ->
        {:ok, nil}

      {value, nil} ->
        {:ok, value}

      {nil, delay} when is_integer(delay) and delay >= 0 ->
        {:ok, System.system_time(:millisecond) + delay}

      _ ->
        {:error, :invalid_schedule}
    end
  end
end
