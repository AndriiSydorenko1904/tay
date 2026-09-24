defmodule Tay.State.CombinedInspection do
  @moduledoc false

  alias Tay.State.{JobIndex, TerminalStore}

  def page(jobs, terminals, query) do
    {total, selected} =
      jobs
      |> JobIndex.fold(&reduce(&1, &2, query), {0, []})
      |> then(&TerminalStore.fold(terminals, fn job, acc -> reduce(job, acc, query) end, &1))

    listed = finalize(selected, query, total)
    offset = offset(query.position, total, length(listed), query.limit)
    count = length(listed)

    %{
      jobs: listed,
      total_count: total,
      next_key: next_key(listed, offset, count, total),
      previous_key: previous_key(listed, offset, query.limit),
      last?: offset + count >= total
    }
  end

  defp reduce(job, {count, selected}, query) do
    if matches?(job, query) do
      {count + 1, select(selected, job, query)}
    else
      {count, selected}
    end
  end

  defp select(selected, job, %{position: nil, limit: limit}),
    do: keep(selected, job, limit, :newest)

  defp select(selected, job, %{position: :last, limit: limit}),
    do: keep(selected, job, limit, :oldest)

  defp select(selected, job, %{position: {:after, cursor, _}, limit: limit}) do
    if key(job) < cursor, do: keep(selected, job, limit, :newest), else: selected
  end

  defp select(selected, job, %{position: {:before, cursor, _}, limit: limit}) do
    if key(job) > cursor, do: keep(selected, job, limit, :oldest), else: selected
  end

  defp keep(selected, job, limit, direction) do
    ordered = Enum.sort_by([job | selected], &key/1, order(direction))
    Enum.take(ordered, limit)
  end

  defp finalize(selected, %{position: :last, limit: limit}, total) do
    page_size = if rem(total, limit) == 0, do: min(total, limit), else: rem(total, limit)

    selected
    |> Enum.take(page_size)
    |> Enum.sort_by(&key/1, :desc)
  end

  defp finalize(selected, %{position: {:before, _, _}}, _total),
    do: Enum.sort_by(selected, &key/1, :desc)

  defp finalize(selected, _, _total), do: selected

  defp order(:newest), do: :desc
  defp order(:oldest), do: :asc

  defp offset(nil, _total, _count, _limit), do: 0
  defp offset(:last, total, count, _limit), do: max(total - count, 0)
  defp offset({:after, _, value}, _total, _count, _limit), do: value || 0
  defp offset({:before, _, value}, _total, _count, _limit), do: value || 0

  defp next_key([], _offset, _count, _total), do: nil
  defp next_key(_jobs, offset, count, total) when offset + count >= total, do: nil
  defp next_key(jobs, offset, count, _total), do: {:after, key(List.last(jobs)), offset + count}

  defp previous_key([], _offset, _limit), do: nil
  defp previous_key(_jobs, 0, _limit), do: nil

  defp previous_key(jobs, offset, limit),
    do: {:before, key(hd(jobs)), max(offset - limit, 0)}

  defp key(job), do: {job.inserted_at, job.id}

  defp matches?(job, query) do
    (is_nil(query.id) or job.id == query.id) and
      (is_nil(query.states) or job.state in query.states) and
      (is_nil(query.queues) or job.definition["queue_key"] in query.queues) and
      (is_nil(query.workers) or job.definition["worker_key"] in query.workers) and
      (is_nil(query.worker_contains) or
         String.contains?(job.definition["worker_key"], query.worker_contains))
  end
end
