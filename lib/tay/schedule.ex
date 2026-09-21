defmodule Tay.Schedule do
  @moduledoc false

  alias Tay.Executor.Protocol
  alias Tay.Schedule.Cron

  @overlap ~w(allow skip queue)
  @catch_up ~w(latest all)

  @enforce_keys [:id, :task, :args, :kind, :expression, :overlap, :catch_up, :next_at]
  defstruct [
    :id,
    :task,
    :args,
    :kind,
    :expression,
    :timezone,
    :overlap,
    :catch_up,
    :next_at,
    :last_at,
    :cancelled_at
  ]

  # This is the canonical, serializable schedule definition used by both the
  # Protocol listener and the durable event layer. `next_at` is always UTC ms.
  def new(id, fields, now)
      when is_binary(id) and is_map(fields) and is_integer(now) and now >= 0 do
    with true <- Protocol.identifier?(id) || {:error, :invalid_schedule_id},
         task when is_binary(task) <- Map.get(fields, "task") || {:error, :invalid_task},
         true <- Protocol.task_key?(task) || {:error, :invalid_task},
         args when is_map(args) <- Map.get(fields, "args", %{}) || {:error, :invalid_args},
         true <- Protocol.json_value?(args) || {:error, :invalid_args},
         {:ok, overlap} <- option(fields, "overlap", "skip", @overlap),
         {:ok, catch_up} <- option(fields, "catch_up", "latest", @catch_up),
         {:ok, kind, expression, timezone, next_at} <- timing(fields, now) do
      {:ok,
       %__MODULE__{
         id: id,
         task: task,
         args: args,
         kind: kind,
         expression: expression,
         timezone: timezone,
         overlap: overlap,
         catch_up: catch_up,
         next_at: next_at,
         last_at: nil,
         cancelled_at: nil
       }}
    else
      _ -> {:error, :invalid_schedule}
    end
  end

  def new(_, _, _), do: {:error, :invalid_schedule}

  def due?(%__MODULE__{cancelled_at: nil, next_at: next_at}, now) when is_integer(now),
    do: next_at <= now

  def due?(_, _), do: false

  def advance(%__MODULE__{kind: :cron, expression: cron} = schedule, at) do
    with {:ok, next_at} <- Cron.next(cron, at),
         do: {:ok, %{schedule | last_at: at, next_at: next_at}}
  end

  def advance(%__MODULE__{kind: :every, expression: interval} = schedule, at) do
    {:ok, %{schedule | last_at: at, next_at: at + interval}}
  end

  def cancel(%__MODULE__{} = schedule, at) when is_integer(at) and at >= 0,
    do: %{schedule | cancelled_at: at}

  defp timing(fields, now) do
    case {Map.get(fields, "cron"), Map.get(fields, "every")} do
      {cron, nil} when is_binary(cron) ->
        timezone = Map.get(fields, "timezone", "+00")

        with {:ok, parsed} <- Cron.parse(cron, timezone),
             {:ok, first} <- first_at(fields, now),
             {:ok, next_at} <- Cron.next(parsed, first - 60_000) do
          {:ok, :cron, parsed, timezone, next_at}
        end

      {nil, every} when is_map(every) ->
        with {:ok, interval} <- interval(every), {:ok, first} <- first_at(fields, now) do
          {:ok, :every, interval, nil, first}
        end

      _ ->
        {:error, :invalid_timing}
    end
  end

  defp first_at(fields, now) do
    case {Map.get(fields, "delay"), Map.get(fields, "start_at")} do
      {nil, nil} -> {:ok, now}
      {delay, nil} when is_number(delay) and delay >= 0 -> {:ok, now + round(delay * 1_000)}
      {nil, start_at} when is_integer(start_at) and start_at >= 0 -> {:ok, start_at}
      _ -> {:error, :invalid_start}
    end
  end

  defp interval(every) do
    values = for {unit, amount} <- every, amount != nil, do: {unit, amount}

    case values do
      [{unit, amount}] when is_number(amount) and amount > 0 ->
        case %{
               "seconds" => 1_000,
               "minutes" => 60_000,
               "hours" => 3_600_000,
               "days" => 86_400_000
             }[unit] do
          nil -> {:error, :invalid_interval}
          multiplier -> {:ok, round(amount * multiplier)}
        end

      _ ->
        {:error, :invalid_interval}
    end
  end

  defp option(fields, key, default, choices) do
    value = Map.get(fields, key, default)
    if value in choices, do: {:ok, value}, else: {:error, :invalid_option}
  end
end
