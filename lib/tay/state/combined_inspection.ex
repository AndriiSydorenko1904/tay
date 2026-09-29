defmodule Tay.State.CombinedInspection do
  @moduledoc false

  alias Tay.State.{InspectionIndex, TerminalStore}

  def page(inspection, jobs, terminals, query) do
    hot = InspectionIndex.candidates(inspection, jobs, query)
    cold = TerminalStore.candidates(terminals, query)
    total = hot.total_count + cold.total_count

    listed =
      (hot.jobs ++ cold.jobs)
      |> Enum.sort_by(&key/1, order(query.position))
      |> Enum.take(query.limit)
      |> finalize(query, total)

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

  defp finalize(selected, %{position: :last, limit: limit}, total) do
    page_size = if rem(total, limit) == 0, do: min(total, limit), else: rem(total, limit)

    selected
    |> Enum.take(page_size)
    |> Enum.sort_by(&key/1, :desc)
  end

  defp finalize(selected, %{position: {:before, _, _}}, _total),
    do: Enum.sort_by(selected, &key/1, :desc)

  defp finalize(selected, _, _total), do: selected

  defp order(:last), do: :asc
  defp order({:before, _, _}), do: :asc
  defp order(_), do: :desc

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
end
