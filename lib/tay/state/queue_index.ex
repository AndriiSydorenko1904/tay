defmodule Tay.State.QueueIndex do
  @moduledoc false
  def new, do: :ets.new(__MODULE__, [:ordered_set, :private])

  def key(job),
    do:
      {job.definition["queue_key"], job.eligible_at,
       Map.get(job, :availability_order, Map.get(job, :available_sequence)), job.id}

  def put(table, job), do: :ets.insert(table, {key(job), job.id})
  def delete(table, job), do: :ets.delete(table, key(job))

  def ready(table, queue, now, limit) when is_integer(limit) and limit > 0,
    do: take(table, :ets.next(table, {queue, -1, -1, <<>>}), queue, now, limit, [])

  defp take(_, _, _, _, 0, acc), do: Enum.reverse(acc)

  defp take(table, {queue, due, _, id} = key, queue, now, n, acc) when due <= now,
    do: take(table, :ets.next(table, key), queue, now, n - 1, [id | acc])

  defp take(_, _, _, _, _, acc), do: Enum.reverse(acc)
end
