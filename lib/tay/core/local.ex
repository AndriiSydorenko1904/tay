defmodule Tay.Core.Local do
  @moduledoc false
  @behaviour Tay.Core.API

  alias Tay.{Error, JobID}
  alias Tay.Engine.Admission
  alias Tay.Event.{V2, Value}

  @impl true
  def enqueue(engine, task, args, options) do
    with {:ok, job} <- Tay.Executor.Job.new(task, args, options),
         {:ok, raw} <- JobID.decode(job.id),
         {:ok, meta} <- ready(engine),
         {:ok, bytes} <- Value.encode(job.definition, meta.value_limits),
         true <- V2.definition?(job.definition) || {:error, :invalid_definition} do
      Admission.request(
        engine,
        meta,
        {:insert, raw, job.worker, bytes, job.durability},
        byte_size(bytes) + 256,
        :insert,
        job.id,
        meta.timeout
      )
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> public_error(reason, :enqueue, safe_id(job_id(options)))
    end
  end

  @impl true
  def get_job(engine, id) do
    with {:ok, raw} <- JobID.decode(id),
         {:ok, meta} <- ready(engine) do
      Admission.request(engine, meta, {:get, raw}, 256, :get_job, id, meta.timeout)
    else
      {:error, reason} -> public_error(reason, :get_job, safe_id(id))
    end
  end

  @impl true
  def cancel(engine, id) do
    with {:ok, raw} <- JobID.decode(id),
         {:ok, %{revision: revision}} <- get_job(engine, id),
         {:ok, meta} <- ready(engine) do
      Admission.request(
        engine,
        meta,
        {:cancel, raw, revision},
        256,
        :cancel,
        id,
        meta.timeout,
        revision
      )
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, %Error{} = error} -> {:error, %{error | operation: :cancel, job_id: safe_id(id)}}
      {:error, reason} -> public_error(reason, :cancel, safe_id(id))
    end
  end

  @impl true
  def result(engine, id) do
    with {:ok, raw} <- JobID.decode(id),
         {:ok, meta} <- ready(engine) do
      Admission.request(engine, meta, {:get_result, raw}, 256, :result, id, meta.timeout)
    else
      {:error, reason} -> public_error(reason, :result, safe_id(id))
    end
  end

  @impl true
  def register_schedule(engine, schedule) do
    with {:ok, meta} <- ready(engine) do
      Admission.request(
        engine,
        meta,
        {:register_schedule, schedule},
        512,
        :register_schedule,
        schedule.id,
        meta.timeout
      )
    else
      {:error, reason} -> public_error(reason, :register_schedule, schedule.id)
    end
  end

  @impl true
  def cancel_schedule(engine, id, revision) do
    schedule_request(
      engine,
      {:cancel_schedule, id, revision, System.system_time(:millisecond)},
      :cancel_schedule,
      id
    )
  end

  @impl true
  def advance_schedule(engine, id, revision, due_at, next_at, at) do
    schedule_request(
      engine,
      {:advance_schedule, id, revision, due_at, next_at, at},
      :advance_schedule,
      id
    )
  end

  defp schedule_request(engine, intent, operation, id) do
    with {:ok, meta} <- ready(engine) do
      Admission.request(engine, meta, intent, 512, operation, id, meta.timeout)
    else
      {:error, reason} -> public_error(reason, operation, id)
    end
  end

  defp ready(engine) do
    case Admission.metadata(engine) do
      {:ok, %{status: %{state: state}} = meta} when state in [:ready, :draining, :drained] ->
        {:ok, meta}

      {:ok, %{status: %{state: :compacting, phase: :preparing}} = meta} ->
        {:ok, meta}

      {:ok, %{status: %{state: :compacting, phase: :switching}} = meta} ->
        await_ready(engine, System.monotonic_time(:millisecond) + meta.timeout)

      _ ->
        {:error, :unavailable}
    end
  end

  defp await_ready(engine, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(1)

      case Admission.metadata(engine) do
        {:ok, %{status: %{state: state}} = meta} when state in [:ready, :draining, :drained] ->
          {:ok, meta}

        {:ok, %{status: %{state: :compacting, phase: :preparing}} = meta} ->
          {:ok, meta}

        {:ok, %{status: %{state: :compacting, phase: :switching}}} ->
          await_ready(engine, deadline)

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  defp job_id(options), do: Keyword.get(options, :id)
  defp safe_id(id), do: if(match?({:ok, _}, JobID.decode(id)), do: id, else: nil)

  defp public_error(:not_found, _operation, _id), do: {:error, :not_found}

  defp public_error(:unavailable, operation, id),
    do: {:error, Error.new(:unavailable, :generation_unavailable, id, operation)}

  defp public_error({:resource_limit, key}, operation, id),
    do: {:error, Error.new(:capacity, key, id, operation)}

  defp public_error(_, operation, id),
    do: {:error, Error.new(:invalid, :invalid_request, id, operation)}
end
