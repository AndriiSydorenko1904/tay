defmodule Tay.State.InspectionIndex do
  @moduledoc false

  @states [:available, :scheduled, :executing, :retryable, :completed, :cancelled, :discarded]
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
    total = matching_count(index.counts, jobs, query)
    {first, step, start_offset, page_limit} = page_start(index.order, query, total)
    listed = scan(index.order, jobs, first, step, query, page_limit, [])
    listed = if step == :next, do: listed, else: Enum.reverse(listed)
    count = length(listed)

    %{
      jobs: listed,
      total_count: total,
      next_key: next_key(listed, start_offset, count, total),
      previous_key: previous_key(listed, start_offset, query.limit),
      last?: start_offset + count >= total
    }
  end

  def entries(index), do: :ets.tab2list(index.order)
  def counts(index), do: Map.new(:ets.tab2list(index.counts))

  def expected(jobs) do
    Enum.reduce(jobs, {[], %{}}, fn job, {entries, counts} ->
      {[{{job.inserted_at, job.id}, job.id} | entries], map_increment(counts, job, 1)}
    end)
  end

  defp page_start(table, %{position: nil, limit: limit}, _total),
    do: {:ets.last(table), :prev, 0, limit}

  defp page_start(table, %{position: {:after, key, offset}, limit: limit}, _total),
    do: {:ets.prev(table, key), :prev, offset || 0, limit}

  defp page_start(table, %{position: {:before, key, offset}, limit: limit}, _total),
    do: {:ets.next(table, key), :next, offset || 0, limit}

  defp page_start(table, %{position: :last, limit: limit}, total) do
    page_size =
      case rem(total, limit) do
        0 -> min(total, limit)
        size -> size
      end

    {:ets.first(table), :next, max(total - page_size, 0), page_size}
  end

  defp scan(_table, _jobs, :"$end_of_table", _step, _query, _limit, acc), do: acc
  defp scan(_table, _jobs, _key, _step, _query, limit, acc) when length(acc) >= limit, do: acc

  defp scan(table, jobs, key, step, query, limit, acc) do
    id = :ets.lookup_element(table, key, 2)
    job = Tay.State.JobIndex.get(jobs, id)
    acc = if matches?(job, query), do: [job | acc], else: acc
    next = apply(:ets, step, [table, key])
    scan(table, jobs, next, step, query, limit, acc)
  end

  defp next_key([], _offset, _count, _total), do: nil
  defp next_key(_jobs, offset, count, total) when offset + count >= total, do: nil
  defp next_key(jobs, offset, count, _total), do: {:after, key(List.last(jobs)), offset + count}

  defp previous_key([], _offset, _limit), do: nil
  defp previous_key(_jobs, 0, _limit), do: nil

  defp previous_key(jobs, offset, limit),
    do: {:before, key(hd(jobs)), max(offset - limit, 0)}

  defp key(job), do: {job.inserted_at, job.id}

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

    update(
      counts,
      {:facet, job.definition["queue_key"], job.state, job.definition["worker_key"]},
      amount
    )
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
    |> map_update(
      {:facet, job.definition["queue_key"], job.state, job.definition["worker_key"]},
      amount
    )
  end

  defp matching_count(_counts, jobs, %{id: id} = query) when not is_nil(id) do
    case Tay.State.JobIndex.get(jobs, id) do
      nil -> 0
      job -> if matches?(job, query), do: 1, else: 0
    end
  end

  defp matching_count(counts, _jobs, query) do
    :ets.foldl(
      fn
        {{:facet, queue, state, worker}, count}, total ->
          if facet_matches?(queue, state, worker, query), do: total + count, else: total

        _, total ->
          total
      end,
      0,
      counts
    )
  end

  defp facet_matches?(queue, state, worker, query) do
    (is_nil(query.states) or state in query.states) and
      (is_nil(query.queues) or queue in query.queues) and
      (is_nil(query.workers) or worker in query.workers) and
      (is_nil(query.worker_contains) or String.contains?(worker, query.worker_contains))
  end

  defp map_update(counts, key, amount), do: Map.update(counts, key, amount, &(&1 + amount))
end
