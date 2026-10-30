defmodule Tay.State.ScheduleIndex do
  @moduledoc false
  @default_limit 50
  @max_limit 100
  @page_bytes 262_144
  def new(schedules) do
    index = %{
      ids: :ets.new(__MODULE__, [:ordered_set, :private]),
      due: :ets.new(__MODULE__, [:ordered_set, :private])
    }

    for {_, schedule} <- schedules, do: put(index, schedule)
    index
  end

  def put(index, schedule) do
    case :ets.lookup(index.ids, schedule.id) do
      [{id, nil, at}] -> :ets.delete(index.due, {at, id})
      _ -> :ok
    end

    :ets.insert(index.ids, {schedule.id, schedule.cancelled_at, schedule.next_at})

    if is_nil(schedule.cancelled_at),
      do: :ets.insert(index.due, {{schedule.next_at, schedule.id}})

    :ok
  end

  def stats(index) do
    active = :ets.info(index.due, :size)

    earliest =
      case :ets.first(index.due) do
        {at, _id} -> at
        :"$end_of_table" -> nil
      end

    %{
      active_schedules: active,
      cancelled_schedules: :ets.info(index.ids, :size) - active,
      schedule_next_at: earliest
    }
  end

  def query(options) when is_map(options) do
    limit = Map.get(options, :limit, @default_limit)
    after_id = Map.get(options, :after)

    if is_integer(limit) and limit in 1..@max_limit and
         (is_nil(after_id) or Tay.Protocol.V1.identifier?(after_id)),
       do: {:ok, %{limit: limit, after: after_id}},
       else: {:error, :invalid_schedule_page}
  end

  def query(_), do: {:error, :invalid_schedule_page}

  def page(index, schedules, query) do
    table = index.ids
    key = if query.after, do: :ets.next(table, query.after), else: :ets.first(table)
    collect(table, schedules, key, query.limit, [], 0)
  end

  defp collect(_table, _schedules, :"$end_of_table", _left, acc, _bytes),
    do: %{schedules: Enum.reverse(acc), next_cursor: nil}

  defp collect(_table, _schedules, _key, 0, acc, _bytes),
    do: %{schedules: Enum.reverse(acc), next_cursor: hd(acc).id}

  defp collect(table, schedules, key, left, acc, bytes) do
    value = Tay.Schedule.view(Map.fetch!(schedules, key))
    size = Tay.State.Memory.bytes(value)

    if acc != [] and bytes + size > @page_bytes do
      %{schedules: Enum.reverse(acc), next_cursor: hd(acc).id}
    else
      collect(table, schedules, :ets.next(table, key), left - 1, [value | acc], bytes + size)
    end
  end
end
