defmodule Tay.State.InspectionIndex do
  @moduledoc false

  @states [:available, :scheduled, :executing, :retryable, :completed, :cancelled, :discarded]
  @scan_limit 1_000

  def new do
    %{
      order: :ets.new(__MODULE__, [:ordered_set, :private]),
      counts: :ets.new(__MODULE__, [:set, :private])
    }
  end

  def replace(index, nil, job) do
    true = :ets.insert(index.order, {{job.inserted_at, job.id}, job.id})
    increment(index.counts, job, 1)
    :ok
  end

  def replace(index, previous, job) do
    true = :ets.insert(index.order, {{job.inserted_at, job.id}, job.id})

    increment(index.counts, previous, -1)
    increment(index.counts, job, 1)
    :ok
  end

  def stats(index), do: Map.new(@states, &{&1, count(index.counts, {:state, &1})})

  def queue_count(index, queue), do: count(index.counts, {:queue, queue})

  def queue_stats(index, queue),
    do: Map.new(@states, &{&1, count(index.counts, {:queue_state, queue, &1})})

  def page(index, jobs, query) do
    first =
      case query.after_key do
        nil -> :ets.last(index.order)
        key -> :ets.prev(index.order, key)
      end

    scan(index.order, jobs, first, query, 0, [], nil)
  end

  def entries(index), do: :ets.tab2list(index.order)
  def counts(index), do: Map.new(:ets.tab2list(index.counts))

  def expected(jobs) do
    Enum.reduce(jobs, {[], %{}}, fn job, {entries, counts} ->
      {[{{job.inserted_at, job.id}, job.id} | entries], map_increment(counts, job, 1)}
    end)
  end

  defp scan(_table, _jobs, :"$end_of_table", _query, _scanned, acc, _last),
    do: {Enum.reverse(acc), nil}

  defp scan(table, jobs, key, query, scanned, acc, _last)
       when scanned < @scan_limit and length(acc) < query.limit do
    id = :ets.lookup_element(table, key, 2)
    job = Tay.State.JobIndex.get(jobs, id)
    acc = if matches?(job, query), do: [job | acc], else: acc
    next = :ets.prev(table, key)

    if next == :"$end_of_table" do
      {Enum.reverse(acc), nil}
    else
      scan(table, jobs, next, query, scanned + 1, acc, key)
    end
  end

  defp scan(_table, _jobs, _key, _query, _scanned, acc, last),
    do: {Enum.reverse(acc), last}

  defp matches?(nil, _query), do: false

  defp matches?(job, query) do
    (is_nil(query.id) or job.id == query.id) and
      (is_nil(query.states) or job.state in query.states) and
      (is_nil(query.queues) or job.definition["queue_key"] in query.queues) and
      (is_nil(query.workers) or job.definition["worker_key"] in query.workers) and
      (is_nil(query.worker_contains) or
         String.contains?(job.definition["worker_key"], query.worker_contains))
  end

  defp increment(counts, job, amount) do
    update(counts, {:state, job.state}, amount)
    update(counts, {:queue, job.definition["queue_key"]}, amount)
    update(counts, {:queue_state, job.definition["queue_key"], job.state}, amount)
    update(counts, {:worker, job.definition["worker_key"]}, amount)
  end

  defp update(table, key, amount) do
    case :ets.update_counter(table, key, {2, amount}, {key, 0}) do
      0 -> :ets.delete(table, key)
      _ -> :ok
    end
  end

  defp count(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp map_increment(counts, job, amount) do
    counts
    |> map_update({:state, job.state}, amount)
    |> map_update({:queue, job.definition["queue_key"]}, amount)
    |> map_update({:queue_state, job.definition["queue_key"], job.state}, amount)
    |> map_update({:worker, job.definition["worker_key"]}, amount)
  end

  defp map_update(counts, key, amount), do: Map.update(counts, key, amount, &(&1 + amount))
end
