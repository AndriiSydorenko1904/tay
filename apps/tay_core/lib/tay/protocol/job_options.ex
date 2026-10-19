defmodule Tay.Protocol.JobOptions do
  @moduledoc false

  alias Tay.Protocol.V1, as: Protocol

  def parse(options) when is_map(options) and not is_struct(options) do
    allowed =
      ~w(submission_id id delay delay_ms run_at retries timeout timeout_ms backoff queue durability)

    if Enum.all?(Map.keys(options), &(&1 in allowed)) do
      with {:ok, id} <- submission_id(options),
           {:ok, delay} <- delay(options),
           {:ok, scheduled} <- run_at(options),
           {:ok, retries} <- integer_option(options, "retries", 0, 65_534),
           {:ok, timeout} <- timeout(options),
           :ok <- backoff(options),
           {:ok, queue} <- queue(options),
           {:ok, durability} <- durability(options) do
        values = [
          id: id,
          retries: retries,
          timeout_ms: timeout,
          queue: queue,
          delay_ms: delay,
          scheduled_at: scheduled,
          durability: durability
        ]

        {:ok, Enum.reject(values, fn {_key, value} -> is_nil(value) end)}
      end
    else
      {:error, :invalid_options}
    end
  end

  def parse(_), do: {:error, :invalid_options}

  defp submission_id(options) do
    case {Map.get(options, "id"), Map.get(options, "submission_id")} do
      {nil, nil} ->
        {:ok, nil}

      {id, nil} ->
        if(match?({:ok, _}, Tay.JobID.decode(id)), do: {:ok, id}, else: {:error, :invalid_id})

      {nil, key} when is_binary(key) ->
        if Protocol.identifier?(key) do
          digest = :crypto.hash(:sha256, "tay-submission-v1:" <> key) |> binary_part(0, 16)
          {:ok, Tay.JobID.encode(if(digest == <<0::128>>, do: <<0::120, 1>>, else: digest))}
        else
          {:error, :invalid_submission_id}
        end

      _ ->
        {:error, :invalid_submission_id}
    end
  end

  defp delay(options) do
    case {Map.get(options, "delay"), Map.get(options, "delay_ms")} do
      {nil, nil} ->
        {:ok, nil}

      {value, nil} when is_integer(value) and value >= 0 ->
        {:ok, value * 1_000}

      {value, nil} when is_float(value) and value >= 0 and value == value ->
        {:ok, round(value * 1_000)}

      {nil, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, :invalid_delay}
    end
  end

  defp run_at(options) do
    case {Map.get(options, "run_at"), Map.get(options, "delay"), Map.get(options, "delay_ms")} do
      {nil, _, _} ->
        {:ok, nil}

      {_value, delay, delay_ms} when not is_nil(delay) or not is_nil(delay_ms) ->
        {:error, :ambiguous_schedule}

      {value, _, _} when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, :invalid_run_at}
    end
  end

  defp integer_option(options, key, default, maximum) do
    case Map.get(options, key, default) do
      value when is_integer(value) and value >= 0 and value <= maximum -> {:ok, value}
      _ -> {:error, :invalid_option}
    end
  end

  defp timeout(options) do
    case {Map.get(options, "timeout"), Map.get(options, "timeout_ms")} do
      {nil, nil} -> {:ok, 30_000}
      {value, nil} when is_integer(value) and value in 1..86_400 -> {:ok, value * 1_000}
      {value, nil} when is_float(value) and value > 0 -> {:ok, round(value * 1_000)}
      {nil, value} when is_integer(value) and value in 1..86_400_000 -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp backoff(options) do
    case Map.get(options, "backoff", "exponential") do
      value when value in [nil, "exponential"] -> :ok
      _ -> {:error, :unsupported_backoff}
    end
  end

  defp queue(options) do
    case Map.get(options, "queue", "default") do
      value when is_binary(value) ->
        if Protocol.task_key?(value), do: {:ok, value}, else: {:error, :invalid_queue}

      _ ->
        {:error, :invalid_queue}
    end
  end

  defp durability(options) do
    case Map.get(options, "durability") do
      nil -> {:ok, nil}
      "persistent" -> {:ok, :persistent}
      "volatile" -> {:ok, :volatile}
      _ -> {:error, :invalid_durability}
    end
  end
end
