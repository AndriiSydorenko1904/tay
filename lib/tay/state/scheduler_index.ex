defmodule Tay.State.SchedulerIndex do
  @moduledoc false
  def new, do: :ets.new(__MODULE__, [:ordered_set, :private])
  def key(job), do: {job.eligible_at, job.id}
  def put(table, job), do: :ets.insert(table, {key(job), job.revision})
  def delete(table, job), do: :ets.delete(table, key(job))

  def due(table, now, limit) when is_integer(limit) and limit > 0,
    do: take(table, :ets.first(table), now, limit, [])

  defp take(_, _, _, 0, acc), do: Enum.reverse(acc)

  defp take(table, {due, id} = key, now, n, acc) when due <= now,
    do: take(table, :ets.next(table, key), now, n - 1, [id | acc])

  defp take(_, _, _, _, acc), do: Enum.reverse(acc)
end
