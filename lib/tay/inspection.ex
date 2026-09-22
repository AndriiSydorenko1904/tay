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
      :id,
      :limit,
      :cursor
    ]

    with true <- keyword?(options, allowed),
         true <- not paired?(options, :state, :states),
         true <- not paired?(options, :queue, :queues),
         true <- not paired?(options, :worker, :workers),
         {:ok, states} <- values(options, :state, :states, &state/1),
         {:ok, queues} <- values(options, :queue, :queues, &key/1),
         {:ok, workers} <- values(options, :worker, :workers, &worker_key/1),
         {:ok, id} <- id(Keyword.get(options, :id)),
         limit when is_integer(limit) and limit in 1..@max_limit <-
           Keyword.get(options, :limit, @default_limit),
         fingerprint = fingerprint(states, queues, workers, id),
         {:ok, after_key} <- decode_cursor(Keyword.get(options, :cursor), fingerprint) do
      {:ok,
       %{
         states: states,
         queues: queues,
         workers: workers,
         id: id,
         limit: limit,
         after_key: after_key,
         fingerprint: fingerprint
       }}
    else
      _ -> {:error, :invalid_query}
    end
  end

  def encode_cursor(nil, _fingerprint), do: nil

  def encode_cursor({inserted_at, id}, fingerprint) do
    Base.url_encode64(<<1, inserted_at::unsigned-64, id::binary-size(16), fingerprint::binary>>,
      padding: false
    )
  end

  def states, do: @states

  defp decode_cursor(nil, _fingerprint), do: {:ok, nil}

  defp decode_cursor(cursor, fingerprint) when is_binary(cursor) do
    with {:ok, <<1, inserted_at::unsigned-64, id::binary-size(16), ^fingerprint::binary>>} <-
           Base.url_decode64(cursor, padding: false),
         true <- V1.time?(inserted_at) and V1.id?(id) do
      {:ok, {inserted_at, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_, _), do: {:error, :invalid_cursor}

  defp fingerprint(states, queues, workers, id) do
    :crypto.hash(:sha256, :erlang.term_to_binary({states, queues, workers, id}, [:deterministic]))
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

  defp keyword?(options, allowed),
    do:
      Keyword.keyword?(options) and length(options) == length(Enum.uniq(Keyword.keys(options))) and
        Enum.all?(Keyword.keys(options), &(&1 in allowed))
end
