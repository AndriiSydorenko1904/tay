defmodule Tay do
  @moduledoc """
  An embedded background job engine with an authoritative append-only log.
  Start an Engine explicitly; application startup only validates configuration
  and starts an empty supervisor. The log is authoritative, while ETS indexes
  and execution state are disposable projections rebuilt after full recovery.

  Tay supports durable insertion, supervised multi-queue execution, scheduling,
  retries, revision-checked cancellation and manual retry, volatile queue
  controls, drain, and explicit fresh-generation stop/restart. Callback effects
  are at-least-once, not exactly-once. Cancellation durably fences future Tay
  outcomes before best-effort termination, but cannot reverse external effects.

  Physical framing validity is separate from Event support and state replay.
  Torn, corrupt or unsupported history preserves evidence and refuses writable
  activation; there is no automatic repair or partial-state publication.
  Submitted calls with lost replies can have unknown outcomes and are not
  automatically retried.

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

  @doc """
  Durably cancels an eligible job. Options are `:name`, `:timeout`, and
  `:expected_revision` (the opaque token from a job view). If the revision option
  is omitted, lookup captures it once. A timeout after submission is an unknown
  outcome carrying that exact token; reconcile explicitly before a new command.
  """
  def cancel(id, options \\ []), do: mutation(:cancel, id, options)

  @doc """
  Expedites retryable work or starts a new cycle for discarded work, retaining
  its immutable definition. Uses the same options and one-capture revision
  semantics as `cancel/2`. Completed/cancelled/available/executing jobs conflict.
  """
  def retry(id, options \\ []), do: mutation(:retry, id, options)

  @doc "Stops new claims for a configured queue after the accepted barrier. Volatile."
  def pause_queue(queue, options \\ []), do: queue_control(:pause_queue, queue, options)

  @doc "Resumes a configured queue; it does not undo an Engine drain."
  def resume_queue(queue, options \\ []), do: queue_control(:resume_queue, queue, options)

  @doc """
  Rejects new inserts/claims and waits for durable settlement and local task death.
  Queued jobs need not execute. Timeout leaves the Engine draining. A submitted
  transport timeout is an unknown control outcome, never implicit resumption.
  """
  def drain(options \\ []) do
    with {:ok, name, timeout} <- request_options(options),
         {:ok, meta} <- ready(name) do
      timeout = timeout || meta.timeout
      deadline = System.monotonic_time(:millisecond) + timeout
      Admission.request(name, meta, {:drain, deadline}, 256, :drain, nil, timeout)
    else
      {:error, reason} -> public_error(reason, :drain, nil)
    end
  end

  @doc """
  Drains then stops the execution generation, retaining its host-supervised
  lifecycle coordinator. `force: true` explicitly skips drain and revokes active
  execution; it is not a successful drain. Options: name, timeout, force.
  """
  def stop(options \\ []), do: lifecycle_control(:stop, options)

  @doc """
  Explicitly replaces the execution generation using fresh full recovery and the
  original validated startup configuration. Never replays a pending client RPC.
  Options: name, timeout, force. Change configuration via host-child replacement.
  """
  def restart(options \\ []), do: lifecycle_control(:restart, options)

  defp lifecycle_control(operation, options) do
    with true <- Config.keyword?(options, [:name, :timeout, :force]) || {:error, :invalid_options},
         force = Keyword.get(options, :force, false),
         true <- is_boolean(force) || {:error, :invalid_options},
         {:ok, name, timeout} <- request_options(Keyword.delete(options, :force)) do
      Tay.Engine.Operations.call(name, operation, force, timeout)
    else
      {:error, reason} -> public_error(reason, operation, nil)
    end
  end

  defp queue_control(operation, queue, options) do
    key = if is_atom(queue), do: Atom.to_string(queue), else: queue

    with true <- V1.key?(key) || {:error, :invalid_queue},
         {:ok, name, timeout} <- request_options(options),
         {:ok, meta} <- ready(name) do
      Admission.request(
        name,
        meta,
        {operation, key},
        256,
        operation,
        nil,
        timeout || meta.timeout
      )
    else
      {:error, reason} -> public_error(reason, operation, nil)
    end
  end

  def status(options \\ []) do
    with {:ok, name, _} <- request_options(options),
         {:ok, status} <- Admission.status(name),
         do: status,
         else: (_ -> %{state: :unavailable, freshness: :bounded_snapshot})
  end

  defp mutation(operation, id, options) do
    with {:ok, raw} <- JobID.decode(id),
         {:ok, name, timeout, revision_option} <- mutation_options(options),
         {:ok, revision} <- mutation_revision(id, name, timeout, revision_option) do
      with {:ok, meta} <- ready(name) do
        Admission.request(
          name,
          meta,
          {operation, raw, revision},
          256,
          operation,
          id,
          timeout || meta.timeout,
          revision
        )
      else
        {:error, reason} -> mutation_error(reason, operation, id, revision)
      end
    else
      {:error, reason} -> mutation_error(reason, operation, safe_id(id), nil)
    end
  end

  defp mutation_options(options) do
    with true <- Config.keyword?(options, [:name, :timeout, :expected_revision]),
         {:ok, name, timeout} <- request_options(Keyword.delete(options, :expected_revision)) do
      case Keyword.fetch(options, :expected_revision) do
        :error ->
          {:ok, name, timeout, :capture}

        {:ok, revision} ->
          if revision_context?(revision),
            do: {:ok, name, timeout, {:supplied, revision}},
            else: {:error, :invalid_revision}
      end
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp mutation_revision(_, _, _, {:supplied, revision}), do: {:ok, revision}

  defp mutation_revision(id, name, timeout, :capture) do
    options = if timeout, do: [name: name, timeout: timeout], else: [name: name]

    case get_job(id, options) do
      {:ok, %Job{revision: revision}} ->
        if revision_context?(revision),
          do: {:ok, revision},
          else: {:error, :unavailable}

      {:error, _} = error ->
        error

      _ ->
        {:error, :unavailable}
    end
  end

  # This bounds transport shape only. Engine validates the exact current STORE,
  # job, generation, and revision; the facade never repairs or refreshes a token.
  defp revision_context?({:tay_revision, store, id, generation, sequence}),
    do:
      is_binary(store) and byte_size(store) == 16 and is_binary(id) and byte_size(id) == 16 and
        is_reference(generation) and V1.sequence?(sequence)

  defp revision_context?(_), do: false

  defp mutation_error(%Error{} = error, operation, id, revision),
    do: {:error, %{error | operation: operation, job_id: id, expected_revision: revision}}

  defp mutation_error(:not_found, _, _, _), do: {:error, :not_found}

  defp mutation_error(reason, operation, id, revision) do
    {:error, error} = public_error(reason, operation, id)
    {:error, %{error | expected_revision: revision}}
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
      {:ok, %{status: %{state: state}} = meta} when state in [:ready, :draining, :drained] ->
        {:ok, meta}

      _ ->
        {:error, :unavailable}
    end
  end

  defp safe_id(id), do: if(match?({:ok, _}, JobID.decode(id)), do: id, else: nil)

  defp public_error(:unavailable, op, id),
    do: {:error, Error.new(:unavailable, :generation_unavailable, id, op)}

  defp public_error({:resource_limit, key}, op, id),
    do: {:error, Error.new(:capacity, key, id, op)}

  defp public_error(_, op, id), do: {:error, Error.new(:invalid, :invalid_request, id, op)}
end
