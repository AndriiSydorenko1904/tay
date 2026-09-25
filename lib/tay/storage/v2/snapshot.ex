defmodule Tay.Storage.V2.Snapshot do
  @moduledoc "Pure canonical snapshot planning. No storage operation occurs here."

  alias Tay.Storage.V2.Codec
  alias Tay.Storage.V2.Retention

  @terminal [:completed, :cancelled, :discarded]

  def classify(job, :infinity, _now) when is_map(job), do: {:ok, :retain}

  def classify(%{state: state, terminal_at: at}, {:hours, hours}, now)
      when state in @terminal do
    with {:ok, expired} <- Retention.expired?(at, {:hours, hours}, now),
         do: {:ok, if(expired, do: :expire, else: :retain)}
  end

  def classify(%{state: state}, {:hours, hours}, now)
      when state not in @terminal do
    with :ok <- Retention.validate({:hours, hours}),
         true <- Tay.Event.V1.time?(now) || {:error, :retention_timestamp_unavailable},
         do: {:ok, :retain}
  end

  def classify(_, _, _), do: {:error, :retention_timestamp_unavailable}

  def plan(jobs, retention \\ :infinity, now \\ 0)

  def plan(jobs, retention, now) when is_map(jobs) do
    with :ok <- validate_source(jobs), do: plan_validated(jobs, retention, now)
  end

  def plan(_, _, _), do: {:error, :invalid_jobs}

  @doc "Validates and canonicalizes state without materializing snapshot payloads."
  def prepare_infinity(jobs) when is_map(jobs) do
    with :ok <- validate_source(jobs) do
      normalized = normalize_availability(jobs)
      {:ok, normalized, Enum.sort(Map.keys(normalized))}
    end
  end

  def prepare_infinity(_), do: {:error, :invalid_jobs}

  @doc "Plans retained canonical state without materializing whole-store payloads."
  def prepare(jobs, retention, captured_at, max_terminal_jobs \\ :infinity)

  def prepare(jobs, retention, captured_at, max_terminal_jobs)
      when is_map(jobs) and
             (max_terminal_jobs == :infinity or
                (is_integer(max_terminal_jobs) and max_terminal_jobs >= 0)) do
    with :ok <- Retention.validate(retention),
         true <- Tay.Event.V1.time?(captured_at) || {:error, :retention_timestamp_unavailable},
         :ok <- validate_source(jobs) do
      Enum.reduce_while(jobs, {:ok, %{}, 0, 0}, fn {id, job}, {:ok, kept, expired, terminals} ->
        case classify(job, retention, captured_at) do
          {:ok, :expire} ->
            {:cont, {:ok, kept, expired + 1, terminals}}

          {:ok, :retain} ->
            {:cont,
             {:ok, Map.put(kept, id, job), expired,
              terminals + if(job.state in @terminal, do: 1, else: 0)}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, kept, expired, terminals} ->
          {kept, pressure_expired} = enforce_terminal_limit(kept, max_terminal_jobs)
          normalized = normalize_availability(kept)

          {:ok, normalized, Enum.sort(Map.keys(normalized)),
           %{
             expired_jobs: expired + pressure_expired,
             pressure_expired_jobs: pressure_expired,
             retained_terminal_jobs: terminals - pressure_expired
           }}

        error ->
          error
      end
    end
  end

  def prepare(_, _, _, _), do: {:error, :invalid_jobs}

  @doc false
  def prepare_online(jobs, retention, captured_at, max_terminal_jobs)
      when is_map(jobs) and
             (max_terminal_jobs == :infinity or
                (is_integer(max_terminal_jobs) and max_terminal_jobs >= 0)) do
    with :ok <- Retention.validate(retention),
         true <- Tay.Event.V1.time?(captured_at) || {:error, :retention_timestamp_unavailable},
         :ok <- validate_source(jobs) do
      Enum.reduce_while(jobs, {:ok, %{}, 0, 0}, fn {id, job}, {:ok, kept, expired, terminals} ->
        case classify(job, retention, captured_at) do
          {:ok, :expire} ->
            {:cont, {:ok, kept, expired + 1, terminals}}

          {:ok, :retain} ->
            {:cont,
             {:ok, Map.put(kept, id, job), expired,
              terminals + if(job.state in @terminal, do: 1, else: 0)}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, kept, expired, terminals} ->
          {kept, pressure_expired} = enforce_terminal_limit(kept, max_terminal_jobs)

          {:ok, kept, Enum.sort(Map.keys(kept)),
           %{
             expired_jobs: expired + pressure_expired,
             pressure_expired_jobs: pressure_expired,
             retained_terminal_jobs: terminals - pressure_expired
           }}

        error ->
          error
      end
    end
  end

  def prepare_online(_, _, _, _), do: {:error, :invalid_jobs}

  defp enforce_terminal_limit(jobs, :infinity), do: {jobs, 0}

  defp enforce_terminal_limit(jobs, limit) do
    terminals =
      jobs
      |> Enum.filter(fn {_, job} -> job.state in @terminal end)
      |> Enum.sort_by(fn {id, job} -> {job.terminal_at, job.inserted_at, id} end, :desc)

    expired = Enum.drop(terminals, limit)
    {Map.drop(jobs, Enum.map(expired, &elem(&1, 0))), length(expired)}
  end

  defp plan_validated(jobs, retention, now) do
    jobs
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.reduce_while({:ok, %{}, 0}, fn {id, job}, {:ok, retained, expired} ->
      case if(Map.get(job, :id) == id,
             do: classify(job, retention, now),
             else: {:error, :job_id_mismatch}
           ) do
        {:ok, :expire} ->
          {:cont, {:ok, retained, expired + 1}}

        {:ok, :retain} ->
          {:cont, {:ok, Map.put(retained, id, job), expired}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, retained, expired} ->
        normalized = normalize_availability(retained)

        normalized
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.reduce_while({:ok, []}, fn {_id, job}, {:ok, records} ->
          case Codec.encode_snapshot(job) do
            {:ok, payload} -> {:cont, {:ok, [payload | records]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, records} ->
            next = 1 + Enum.count(normalized, fn {_, job} -> job.state == :available end)
            {:ok, Enum.reverse(records), %{expired_jobs: expired, next_availability_order: next}}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc "Canonicalizes the storage-internal global availability coordinate."
  def normalize_availability(jobs) when is_map(jobs) do
    jobs
    |> Enum.filter(fn {_, job} -> job.state == :available end)
    |> Enum.sort_by(fn {id, job} ->
      {job.definition["queue_key"], job.eligible_at, job.availability_order, id}
    end)
    |> Enum.with_index(1)
    |> Enum.reduce(jobs, fn {{id, job}, order}, acc ->
      Map.put(acc, id, Map.put(job, :availability_order, order))
    end)
  end

  def equivalent?(before, after_state) when is_map(before) and is_map(after_state) do
    with :ok <- validate_source(before),
         :ok <- validate_source(after_state) do
      durable(normalize_availability(before)) == durable(normalize_availability(after_state))
    else
      _ -> false
    end
  end

  def equivalent?(_, _), do: false

  defp durable(jobs),
    do: Map.new(jobs, fn {id, job} -> {id, Map.drop(job, [:charge])} end)

  defp validate_source(jobs) do
    Enum.reduce_while(jobs, {:ok, MapSet.new()}, fn {id, job}, {:ok, orders} ->
      order = if is_map(job), do: Map.get(job, :availability_order)

      cond do
        not is_map(job) ->
          {:halt, {:error, :invalid_snapshot}}

        Map.get(job, :id) != id ->
          {:halt, {:error, :job_id_mismatch}}

        MapSet.member?(orders, order) and not is_nil(order) ->
          {:halt, {:error, :duplicate_availability_order}}

        true ->
          case Codec.snapshot?(job) do
            :ok -> {:cont, {:ok, if(order, do: MapSet.put(orders, order), else: orders)}}
            error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
