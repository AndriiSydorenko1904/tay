defmodule Tay.State.TaskIndex do
  @moduledoc false

  # The ordinary queue index intentionally contains only statically dispatchable
  # BEAM jobs.  External runtimes come and go, so putting all of their work in
  # that index would make the first unavailable capability a head-of-line
  # blocker.  This second, private index preserves the same deterministic order
  # within a task capability while allowing the Engine to select among the
  # capabilities that currently have capacity.
  def new, do: :ets.new(__MODULE__, [:ordered_set, :private])

  def key(job),
    do:
      {job.definition["queue_key"], job.definition["worker_key"], job.eligible_at,
       job.available_sequence, job.id}

  def put(table, job), do: :ets.insert(table, {key(job), job.id})
  def delete(table, job), do: :ets.delete(table, key(job))

  def ready(table, queue, task, now, limit)
      when is_binary(queue) and is_binary(task) and is_integer(limit) and limit > 0 do
    take(table, :ets.next(table, {queue, task, -1, -1, <<>>}), queue, task, now, limit, [])
  end

  def ready(_, _, _, _, _), do: []

  defp take(_, _, _, _, _, 0, acc), do: Enum.reverse(acc)

  defp take(table, {queue, task, due, _, id} = key, queue, task, now, n, acc) when due <= now,
    do: take(table, :ets.next(table, key), queue, task, now, n - 1, [id | acc])

  defp take(_, _, _, _, _, _, acc), do: Enum.reverse(acc)
end
