defmodule Tay.Inspection do
  @moduledoc false
  alias Tay.Event.V1
  alias Tay.JobID

  @states [:available, :scheduled, :executing, :retryable, :completed, :cancelled, :discarded]
  @default_limit 50
  @max_limit 100
  @max_filter_values 32

  def normalize(options) do
    allowed = [
      :name,
      :timeout,
      :state,
      :states,
      :queue,
      :queues,
      :worker,
      :workers,
      :worker_contains,
      :id,
      :limit,
      :cursor
    ]

    with true <- keyword?(options, allowed),
         true <- not paired?(options, :state, :states),
         true <- not paired?(options, :queue, :queues),
         true <- not paired?(options, :worker, :workers),
         true <- not mixed_worker_filter?(options),
         {:ok, states} <- values(options, :state, :states, &state/1),
         {:ok, queues} <- values(options, :queue, :queues, &key/1),
         {:ok, workers} <- values(options, :worker, :workers, &worker_key/1),
         {:ok, worker_contains} <- optional(options, :worker_contains, &key/1),
         {:ok, id} <- id(Keyword.get(options, :id)),
         limit when is_integer(limit) and limit in 1..@max_limit <-
           Keyword.get(options, :limit, @default_limit),
         fingerprint = fingerprint(states, queues, workers, worker_contains, id),
         {:ok, position} <- decode_cursor(Keyword.get(options, :cursor), fingerprint) do
      {:ok,
       %{
         states: states,
         queues: queues,
         workers: workers,
         worker_contains: worker_contains,
         id: id,
         limit: limit,
         position: position,
         fingerprint: fingerprint
       }}
    else
      _ -> {:error, :invalid_query}
    end
  end

  def encode_cursor(nil, _fingerprint), do: nil

  def encode_cursor({direction, {inserted_at, id}, offset}, fingerprint)
      when direction in [:after, :before] and is_integer(offset) and offset >= 0 do
    direction = if direction == :after, do: 0, else: 1

    Base.url_encode64(
      <<2, direction, offset::unsigned-64, inserted_at::unsigned-64, id::binary-size(16),
        fingerprint::binary>>,
      padding: false
    )
  end

  def encode_cursor(:last, fingerprint),
    do: Base.url_encode64(<<2, 2, fingerprint::binary>>, padding: false)

  def states, do: @states

  defp decode_cursor(nil, _fingerprint), do: {:ok, nil}

  defp decode_cursor(cursor, fingerprint) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false) do
      decode_position(decoded, fingerprint)
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_, _), do: {:error, :invalid_cursor}

  defp decode_position(
         <<2, direction, offset::unsigned-64, inserted_at::unsigned-64, id::binary-size(16),
           fingerprint::binary>>,
         fingerprint
       )
       when direction in [0, 1] do
    if V1.time?(inserted_at) and V1.id?(id) do
      {:ok, {if(direction == 0, do: :after, else: :before), {inserted_at, id}, offset}}
    else
      {:error, :invalid_cursor}
    end
  end

  defp decode_position(<<2, 2, fingerprint::binary>>, fingerprint), do: {:ok, :last}

  # Version-one cursors remain readable so bookmarked dashboard pages keep working.
  defp decode_position(
         <<1, inserted_at::unsigned-64, id::binary-size(16), fingerprint::binary>>,
         fingerprint
       ) do
    if V1.time?(inserted_at) and V1.id?(id),
      do: {:ok, {:after, {inserted_at, id}, nil}},
      else: {:error, :invalid_cursor}
  end

  defp decode_position(_, _), do: {:error, :invalid_cursor}

  defp fingerprint(states, queues, workers, worker_contains, id) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({states, queues, workers, worker_contains, id}, [:deterministic])
    )
  end

  defp optional(options, key, validator) do
    case Keyword.fetch(options, key) do
      :error -> {:ok, nil}
      {:ok, value} -> validator.(value)
    end
  end

  defp values(options, singular, plural, validator) do
    case Keyword.fetch(options, singular) do
      {:ok, value} -> normalize_values([value], validator)
      :error -> normalize_values(Keyword.get(options, plural), validator)
    end
  end

  defp normalize_values(nil, _validator), do: {:ok, nil}

  defp normalize_values(values, validator) when is_list(values) do
    with true <- values != [] and length(values) <= @max_filter_values,
         {:ok, normalized} <- map_values(values, validator),
         normalized = Enum.sort(normalized),
         true <- length(normalized) == length(Enum.uniq(normalized)) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_filter}
    end
  end

  defp normalize_values(_, _), do: {:error, :invalid_filter}

  defp map_values(values, validator) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case validator.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, :invalid_filter}}
      end
    end)
  end

  defp state(value) when value in @states, do: {:ok, value}
  defp state(_), do: :error

  defp key(value) when is_atom(value) and value not in [nil, false, true],
    do: key(Atom.to_string(value))

  defp key(value) when is_binary(value), do: if(V1.key?(value), do: {:ok, value}, else: :error)
  defp key(_), do: :error

  defp worker_key(value) when is_binary(value), do: key(value)

  defp worker_key(value) when is_atom(value) and value not in [nil, false, true] do
    with true <- function_exported?(value, :__tay_worker__, 0),
         options when is_list(options) <- value.__tay_worker__(),
         worker_key when is_binary(worker_key) <- Keyword.get(options, :worker_key) do
      key(worker_key)
    else
      _ -> :error
    end
  end

  defp worker_key(_), do: :error

  defp id(nil), do: {:ok, nil}
  defp id(value), do: JobID.decode(value)

  defp paired?(options, one, many),
    do: Keyword.has_key?(options, one) and Keyword.has_key?(options, many)

  defp mixed_worker_filter?(options) do
    Keyword.has_key?(options, :worker_contains) and
      (Keyword.has_key?(options, :worker) or Keyword.has_key?(options, :workers))
  end

  defp keyword?(options, allowed),
    do:
      Keyword.keyword?(options) and length(options) == length(Enum.uniq(Keyword.keys(options))) and
        Enum.all?(Keyword.keys(options), &(&1 in allowed))
end
