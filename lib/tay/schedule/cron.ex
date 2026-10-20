defmodule Tay.Schedule.Cron do
  @moduledoc false

  # A deliberately small, deterministic Unix-crontab evaluator.  Schedules
  # retain a numeric UTC offset instead of a named-zone database: that makes a
  # persisted definition reproducible after restart and independent of host
  # tzdata changes.
  @limits [{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}]
  @max_search_minutes 5 * 366 * 24 * 60

  @type t :: %{
          minute: MapSet.t(integer()),
          hour: MapSet.t(integer()),
          day_of_month: MapSet.t(integer()),
          month: MapSet.t(integer()),
          day_of_week: MapSet.t(integer()),
          dom_any?: boolean(),
          dow_any?: boolean(),
          offset_minutes: integer()
        }

  def parse(expression, timezone \\ "+00")

  def parse(expression, timezone) when is_binary(expression) and is_binary(timezone) do
    with [minute, hour, day_of_month, month, day_of_week] <-
           String.split(expression, ~r/\s+/, trim: true),
         {:ok, offset_minutes} <- timezone_offset(timezone),
         {:ok, minute} <- field(minute, Enum.at(@limits, 0)),
         {:ok, hour} <- field(hour, Enum.at(@limits, 1)),
         {:ok, day_of_month} <- field(day_of_month, Enum.at(@limits, 2)),
         {:ok, month} <- field(month, Enum.at(@limits, 3)),
         {:ok, day_of_week} <- field(day_of_week, Enum.at(@limits, 4)) do
      {:ok,
       %{
         minute: minute,
         hour: hour,
         day_of_month: day_of_month,
         month: month,
         day_of_week: normalize_weekdays(day_of_week),
         dom_any?: day_of_month == :any,
         dow_any?: day_of_week == :any,
         offset_minutes: offset_minutes
       }
       |> normalize_any()}
    else
      _ -> {:error, :invalid_cron}
    end
  end

  def parse(_, _), do: {:error, :invalid_cron}

  # Returns the first UTC millisecond strictly later than `after_ms` whose
  # local wall-clock minute matches the cron expression.
  def next(%{} = cron, after_ms) when is_integer(after_ms) and after_ms >= 0 do
    first = div(after_ms, 60_000) * 60_000 + 60_000
    seek(cron, first, @max_search_minutes)
  end

  def next(_, _), do: {:error, :invalid_time}

  def timezone_offset("UTC"), do: {:ok, 0}
  def timezone_offset("Z"), do: {:ok, 0}

  def timezone_offset(<<sign::binary-size(1), rest::binary>>)
      when sign in ["+", "-"] and byte_size(rest) == 5 do
    with [hours, minutes] <- String.split(rest, ":", parts: 2),
         {hour, ""} <- Integer.parse(hours),
         {minute, ""} <- Integer.parse(minutes),
         true <- hour in 0..23 and minute in 0..59 do
      direction = if sign == "+", do: 1, else: -1
      {:ok, direction * (hour * 60 + minute)}
    else
      _ -> {:error, :invalid_timezone}
    end
  end

  def timezone_offset(value) when is_binary(value) do
    case Regex.run(~r/^([+-])(\d{2})$/, value) do
      [_, sign, hour] ->
        case Integer.parse(hour) do
          {number, ""} when number in 0..23 ->
            {:ok, if(sign == "+", do: number * 60, else: -number * 60)}

          _ ->
            {:error, :invalid_timezone}
        end

      _ ->
        {:error, :invalid_timezone}
    end
  end

  def timezone_offset(_), do: {:error, :invalid_timezone}

  defp seek(_, _, 0), do: {:error, :no_next_occurrence}

  defp seek(cron, utc_ms, remaining) do
    local = DateTime.from_unix!(utc_ms + cron.offset_minutes * 60_000, :millisecond)

    if matches?(cron, local) do
      {:ok, utc_ms}
    else
      seek(cron, utc_ms + 60_000, remaining - 1)
    end
  end

  defp matches?(cron, local) do
    MapSet.member?(cron.minute, local.minute) and MapSet.member?(cron.hour, local.hour) and
      MapSet.member?(cron.month, local.month) and day_matches?(cron, local)
  end

  # Unix cron uses OR only when both day fields are restricted.
  defp day_matches?(%{dom_any?: true, dow_any?: true}, _), do: true

  defp day_matches?(%{dom_any?: true, day_of_week: dow}, local),
    do: MapSet.member?(dow, weekday(local))

  defp day_matches?(%{dow_any?: true, day_of_month: dom}, local),
    do: MapSet.member?(dom, local.day)

  defp day_matches?(%{day_of_month: dom, day_of_week: dow}, local),
    do: MapSet.member?(dom, local.day) or MapSet.member?(dow, weekday(local))

  defp weekday(local), do: rem(Date.day_of_week(DateTime.to_date(local)), 7)

  defp normalize_any(cron) do
    Map.update!(cron, :minute, &any_to_full(&1, {0, 59}))
    |> Map.update!(:hour, &any_to_full(&1, {0, 23}))
    |> Map.update!(:day_of_month, &any_to_full(&1, {1, 31}))
    |> Map.update!(:month, &any_to_full(&1, {1, 12}))
    |> Map.update!(:day_of_week, &any_to_full(&1, {0, 6}))
  end

  defp any_to_full(:any, {low, high}), do: MapSet.new(low..high)
  defp any_to_full(values, _), do: values

  defp normalize_weekdays(:any), do: :any

  defp normalize_weekdays(values),
    do:
      values
      |> Enum.map(fn
        7 -> 0
        day -> day
      end)
      |> MapSet.new()

  defp field("*", _limits), do: {:ok, :any}

  defp field(value, {low, high}) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, values} ->
      case field_part(part, low, high) do
        {:ok, part_values} -> {:cont, {:ok, MapSet.union(values, part_values)}}
        error -> {:halt, error}
      end
    end)
  end

  defp field_part(part, low, high) do
    case String.split(part, "/", parts: 2) do
      [base] ->
        range(base, low, high, 1)

      [base, step] ->
        case Integer.parse(step) do
          {n, ""} when n > 0 -> range(base, low, high, n)
          _ -> {:error, :invalid_cron}
        end
    end
  end

  defp range("*", low, high, step),
    do: {:ok, MapSet.new(Stream.iterate(low, &(&1 + step)) |> Enum.take_while(&(&1 <= high)))}

  defp range(value, low, high, step) do
    case String.split(value, "-", parts: 2) do
      [single] ->
        with {number, ""} <- Integer.parse(single), true <- number in low..high do
          {:ok, MapSet.new([number])}
        else
          _ -> {:error, :invalid_cron}
        end

      [first, last] ->
        with {start, ""} <- Integer.parse(first),
             {finish, ""} <- Integer.parse(last),
             true <- start in low..high and finish in start..high do
          {:ok,
           MapSet.new(Stream.iterate(start, &(&1 + step)) |> Enum.take_while(&(&1 <= finish)))}
        else
          _ -> {:error, :invalid_cron}
        end
    end
  end
end
