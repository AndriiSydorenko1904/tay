defmodule Tay.Job do
  @moduledoc """
  A runtime job description, never a persisted representation.

  A new struct has no ID, lifecycle state, or timestamps. Constructing one
  neither inserts a job nor marks it available for execution. `new/3` constructs
  a validated immutable definition and ID but does not access storage.

  Only the independent Event v1 schema defines persistence. The `definition`
  field is the immutable insertion intent used for reconciliation; editing
  presentation fields does not create a new definition. Construct a new job
  explicitly to change that intent. Recovered views can lack runtime mappings.
  """

  defstruct id: nil,
            worker: nil,
            queue: :default,
            args: %{},
            state: nil,
            attempt: 0,
            max_attempts: 10,
            inserted_at: nil,
            scheduled_at: nil,
            attempted_at: nil,
            completed_at: nil,
            errors: [],
            worker_key: nil,
            definition: nil,
            revision: nil,
            timeout_ms: 30_000

  @type t :: %__MODULE__{
          id: binary() | nil,
          worker: module() | nil,
          queue: atom() | String.t(),
          args: map(),
          state: atom() | nil,
          attempt: non_neg_integer(),
          max_attempts: pos_integer(),
          inserted_at: DateTime.t() | non_neg_integer() | nil,
          scheduled_at: DateTime.t() | non_neg_integer() | nil,
          attempted_at: DateTime.t() | non_neg_integer() | nil,
          completed_at: DateTime.t() | non_neg_integer() | nil,
          errors: [term()],
          worker_key: String.t() | nil,
          definition: map() | nil,
          revision: term(),
          timeout_ms: pos_integer()
        }

  alias Tay.{Error, JobID}
  alias Tay.Event.{Value, V1}
  @options [:id, :worker_key, :queue, :max_attempts, :timeout_ms, :scheduled_at]

  def new(worker, args, options \\ []) do
    with true <-
           (is_atom(worker) and worker not in [nil, false, true]) || {:error, :invalid_worker},
         true <- valid_options?(options) || {:error, :invalid_options},
         defaults = defaults(worker),
         true <- valid_options?(defaults) || {:error, :invalid_worker_defaults},
         opts = Keyword.merge(defaults, options),
         {:ok, scheduled} <- schedule(Keyword.get(opts, :scheduled_at)),
         definition = %{
           "definition_version" => 1,
           "args" => args,
           "worker_key" => Keyword.get(opts, :worker_key),
           "queue_key" => queue_key(Keyword.get(opts, :queue, :default)),
           "max_attempts" => Keyword.get(opts, :max_attempts, 10),
           "timeout_ms" => Keyword.get(opts, :timeout_ms, 30_000),
           "scheduled_at" => scheduled,
           "retry_policy" => V1.policy()
         },
         {:ok, _} <- Value.measure(definition),
         true <- V1.definition?(definition) || {:error, :invalid_definition},
         id = Keyword.get_lazy(opts, :id, &JobID.new/0),
         {:ok, _} <- JobID.decode(id) do
      {:ok,
       %__MODULE__{
         id: id,
         worker: worker,
         worker_key: definition["worker_key"],
         queue: Keyword.get(opts, :queue, :default),
         args: args,
         definition: definition,
         max_attempts: definition["max_attempts"],
         timeout_ms: definition["timeout_ms"],
         scheduled_at: scheduled
       }}
    else
      {:error, {:resource_limit, reason}} -> {:error, Error.new(:resource_limit, reason)}
      {:error, reason} -> {:error, Error.new(:invalid, reason)}
    end
  end

  defp defaults(worker) do
    if function_exported?(worker, :__tay_worker__, 0), do: worker.__tay_worker__(), else: []
  end

  defp valid_options?(opts),
    do:
      Keyword.keyword?(opts) and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
        Enum.all?(Keyword.keys(opts), &(&1 in @options))

  defp queue_key(queue) when is_atom(queue) and queue not in [nil, false, true],
    do: Atom.to_string(queue)

  defp queue_key(queue) when is_binary(queue), do: queue
  defp queue_key(_), do: nil
  defp schedule(nil), do: {:ok, nil}

  defp schedule(%DateTime{} = dt) do
    schedule(DateTime.to_unix(dt, :millisecond))
  rescue
    _ -> {:error, :invalid_schedule}
  end

  defp schedule(n), do: if(V1.time?(n), do: {:ok, n}, else: {:error, :invalid_schedule})

  @doc false
  def view(job, registry, queues, store_id, generation, epoch_id \\ nil) do
    d = job.definition

    %__MODULE__{
      id: JobID.encode(job.id),
      definition: d,
      worker_key: d["worker_key"],
      worker: Map.get(registry, d["worker_key"]),
      queue: Map.get(queues, d["queue_key"], d["queue_key"]),
      args: d["args"],
      state: job.state,
      attempt: job.attempt,
      max_attempts: d["max_attempts"],
      timeout_ms: d["timeout_ms"],
      inserted_at: present_time(job.inserted_at),
      scheduled_at: present_time(job.eligible_at),
      attempted_at: present_time(job.attempted_at),
      completed_at: present_time(job.completed_at),
      errors: if(job.diagnostic, do: [job.diagnostic], else: []),
      revision:
        if(epoch_id,
          do: {:tay_revision_v2, store_id, epoch_id, job.id, generation, job.revision},
          else: {:tay_revision, store_id, job.id, generation, job.revision}
        )
    }
  end

  defp present_time(nil), do: nil

  defp present_time(n) do
    case DateTime.from_unix(n, :millisecond) do
      {:ok, dt} -> dt
      {:error, _} -> n
    end
  end
end
