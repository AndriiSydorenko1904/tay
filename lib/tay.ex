defmodule Tay do
  @moduledoc """
  The foundation of an embedded background job engine for Elixir.

  Phase 0 provides configuration, application startup, a runtime `Tay.Job`
  struct, and the `Tay.Worker` behaviour. Starting the application validates
  configuration and starts an empty supervisor.

  Phase 1 adds the pure `Tay.Storage.Record` framing/integrity codec with opaque
  payloads. Physical decoding is not semantic acceptance or applied replay.

  Phase 4 adds explicit Engine supervision, durable insertion, lookup and
  same-ID reconciliation using Phase 3 fail-closed recovery. Application startup
  remains storage-free. No worker execution or scheduling occurs in Phase 4.

  Initialize storage explicitly with `Tay.Storage.initialize/1`, then supervise
  `Tay.child_spec/1`. Engine options are not `:tay` application environment keys.
  `:sync` requires an explicitly validated Linux filesystem; explicit `:write`
  is a development mode and is never described as durable.
  """
  alias Tay.{Error, Job, JobID}
  alias Tay.Engine.{Admission, Config}
  alias Tay.Event.{Value, V1}

  def child_spec(options) do
    %{
      id: {Tay.Engine.Supervisor, Keyword.get(options, :name, Tay.Engine)},
      start: {__MODULE__, :start_link, [options]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link(options) do
    with {:ok, config} <- Config.new(options), do: Tay.Engine.Supervisor.start_link(config)
  end

  def insert(job, options \\ [])
  def insert({:ok, %Job{} = job}, options), do: insert(job, options)
  def insert({:error, _} = error, _options), do: error

  def insert(%Job{} = job, options) do
    with {:ok, raw} <- JobID.decode(job.id),
         true <-
           (is_atom(job.worker) and job.worker not in [false, true]) || {:error, :invalid_worker},
         {:ok, name, timeout} <- request_options(options),
         {:ok, meta} <- ready(name),
         {:ok, bytes} <- Value.encode(job.definition, meta.value_limits),
         true <- V1.definition?(job.definition) || {:error, :invalid_definition} do
      Admission.request(
        name,
        meta,
        {:insert, raw, job.worker, bytes},
        byte_size(bytes) + 256,
        :insert,
        job.id,
        timeout || meta.timeout
      )
    else
      {:error, reason} -> public_error(reason, :insert, safe_id(job.id))
    end
  end

  def insert(_, _), do: {:error, Error.new(:invalid, :invalid_job, nil, :insert)}

  def get_job(id, options \\ []) do
    with {:ok, raw} <- JobID.decode(id),
         {:ok, name, timeout} <- request_options(options),
         {:ok, meta} <- ready(name) do
      Admission.request(name, meta, {:get, raw}, 256, :get_job, id, timeout || meta.timeout)
    else
      {:error, reason} -> public_error(reason, :get_job, safe_id(id))
    end
  end

  def status(options \\ []) do
    with {:ok, name, _} <- request_options(options),
         {:ok, status} <- Admission.status(name),
         do: status,
         else: (_ -> %{state: :unavailable, freshness: :bounded_snapshot})
  end

  defp request_options(options) do
    if Config.keyword?(options, [:name, :timeout]) do
      name = Keyword.get(options, :name, Tay.Engine)
      timeout = Keyword.get(options, :timeout)

      if is_atom(name) and name not in [nil, false, true] and
           (is_nil(timeout) or (is_integer(timeout) and timeout in 1..4_294_967_295)),
         do: {:ok, name, timeout},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp ready(name) do
    case Admission.metadata(name) do
      {:ok, %{status: %{state: :ready}} = meta} -> {:ok, meta}
      _ -> {:error, :unavailable}
    end
  end

  defp safe_id(id), do: if(match?({:ok, _}, JobID.decode(id)), do: id, else: nil)

  defp public_error(:unavailable, op, id),
    do: {:error, Error.new(:unavailable, :generation_unavailable, id, op)}

  defp public_error({:resource_limit, key}, op, id),
    do: {:error, Error.new(:capacity, key, id, op)}

  defp public_error(_, op, id), do: {:error, Error.new(:invalid, :invalid_request, id, op)}
end
