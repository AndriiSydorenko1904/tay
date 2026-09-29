defmodule Tay.State.TerminalStore do
  @moduledoc "Disk-backed disposable projection for terminal job history."

  @terminal [:completed, :cancelled, :discarded]
  @slots 0..3

  defstruct [:table, :file, :registry, :slot, :order, :counts]

  def open(name, data_dir, jobs) when is_atom(name) and is_binary(data_dir) and is_map(jobs) do
    :ok = File.mkdir_p(Path.dirname(data_dir))

    Enum.reduce_while(@slots, {:error, :terminal_projection_unavailable}, fn slot, _error ->
      file = data_dir <> ".terminal.#{slot}.dets"

      case claim_and_open(name, slot, file) do
        {:ok, table} ->
          order = :ets.new(__MODULE__, [:ordered_set, :private])
          counts = :ets.new(__MODULE__, [:set, :private])

          with :ok <- :dets.delete_all_objects(table),
               :ok <- load(table, order, counts, jobs),
               :ok <- :dets.sync(table) do
            {:halt,
             {:ok,
              %__MODULE__{
                table: table,
                file: file,
                registry: name,
                slot: slot,
                order: order,
                counts: counts
              }}}
          else
            error ->
              :dets.close(table)
              release(name, slot)
              {:halt, error}
          end

        false ->
          {:cont, {:error, :terminal_projection_slot_busy}}

        {:error, _} = error ->
          release(name, slot)
          {:cont, error}
      end
    end)
  end

  def close(%__MODULE__{
        table: table,
        file: file,
        registry: registry,
        slot: slot,
        order: order,
        counts: counts
      }) do
    result = :dets.close(table)
    _ = File.rm(file)
    :ets.delete(order)
    :ets.delete(counts)
    release(registry, slot)
    result
  end

  def get(%__MODULE__{table: table}, id) do
    case :dets.lookup(table, id) do
      [{^id, job}] -> job
      [] -> nil
    end
  end

  def put(%__MODULE__{} = store, job) do
    previous = get(store, job.id)

    with :ok <- :dets.insert(store.table, {job.id, job}) do
      if previous, do: remove_index(store, previous)
      add_index(store, job)
      :ok
    end
  end

  def delete(%__MODULE__{} = store, id) do
    previous = get(store, id)

    with :ok <- :dets.delete(store.table, id) do
      if previous, do: remove_index(store, previous)
      :ok
    end
  end

  def count(%__MODULE__{table: table}), do: :dets.info(table, :size)

  def candidates(%__MODULE__{} = store, query) do
    total = matching_count(store, query)
    {first, step} = candidate_start(store.order, query)
    jobs = scan(store, first, step, query, query.limit, [])
    %{jobs: Enum.reverse(jobs), total_count: total}
  end

  def fold(%__MODULE__{table: table}, fun, accumulator),
    do: :dets.foldl(fn {_id, job}, acc -> fun.(job, acc) end, accumulator, table)

  defp open_file(file),
    do: :dets.open_file(make_ref(), file: String.to_charlist(file), type: :set, repair: :force)

  defp claim_and_open(registry, slot, file) do
    if claim(registry, slot) do
      _ = File.rm(file)
      open_file(file)
    else
      false
    end
  end

  defp claim(registry, slot) do
    key = {:terminal_projection, slot}

    case :ets.lookup(registry, key) do
      [{^key, owner}] when is_pid(owner) ->
        if Process.alive?(owner), do: false, else: :ets.delete_object(registry, {key, owner})

      [] ->
        :ok
    end

    :ets.insert_new(registry, {key, self()})
  end

  defp release(registry, slot),
    do: :ets.delete_object(registry, {{:terminal_projection, slot}, self()})

  defp load(table, order, counts, jobs) do
    store = %__MODULE__{table: table, order: order, counts: counts}

    {batch, _size} =
      Enum.reduce(jobs, {[], 0}, fn
        {_id, %{state: state} = job}, {batch, size} when state in @terminal ->
          add_index(store, job)
          batch = [{job.id, job} | batch]

          if size == 999, do: {flush(table, batch), 0}, else: {batch, size + 1}

        _, accumulator ->
          accumulator
      end)

    flush(table, batch)

    :ok
  end

  defp flush(_table, []), do: []

  defp flush(table, batch) do
    :ok = :dets.insert(table, batch)
    []
  end

  defp add_index(store, job) do
    true =
      :ets.insert(store.order, {
        key(job),
        {job.id, job.state, job.definition["queue_key"], job.definition["worker_key"]}
      })

    increment(
      store.counts,
      job.state,
      job.definition["queue_key"],
      job.definition["worker_key"],
      1
    )
  end

  defp remove_index(store, job) do
    :ets.delete(store.order, key(job))

    increment(
      store.counts,
      job.state,
      job.definition["queue_key"],
      job.definition["worker_key"],
      -1
    )
  end

  defp increment(counts, state, queue, worker, amount) do
    for key <- [{:state, state}, {:facet, queue, state, worker}] do
      case :ets.update_counter(counts, key, {2, amount}, {key, 0}) do
        0 -> :ets.delete(counts, key)
        _ -> :ok
      end
    end

    :ok
  end

  defp matching_count(store, %{id: id} = query) when not is_nil(id) do
    case get(store, id) do
      nil -> 0
      job -> if matches_job?(job, query), do: 1, else: 0
    end
  end

  defp matching_count(store, query) do
    :ets.foldl(
      fn
        {{:facet, queue, state, worker}, count}, total ->
          if matches_metadata?(nil, state, queue, worker, query), do: total + count, else: total

        _, total ->
          total
      end,
      0,
      store.counts
    )
  end

  defp candidate_start(table, %{position: nil}), do: {:ets.last(table), :prev}
  defp candidate_start(table, %{position: {:after, key, _}}), do: {:ets.prev(table, key), :prev}
  defp candidate_start(table, %{position: {:before, key, _}}), do: {:ets.next(table, key), :next}
  defp candidate_start(table, %{position: :last}), do: {:ets.first(table), :next}

  defp scan(_store, :"$end_of_table", _step, _query, _limit, acc), do: acc
  defp scan(_store, _key, _step, _query, limit, acc) when length(acc) >= limit, do: acc

  defp scan(store, key, step, query, limit, acc) do
    {id, state, queue, worker} = :ets.lookup_element(store.order, key, 2)

    acc =
      if matches_metadata?(id, state, queue, worker, query) do
        case :dets.lookup(store.table, id) do
          [{^id, job}] -> [job | acc]
          [] -> acc
        end
      else
        acc
      end

    scan(store, apply(:ets, step, [store.order, key]), step, query, limit, acc)
  end

  defp matches_job?(job, query),
    do:
      matches_metadata?(
        job.id,
        job.state,
        job.definition["queue_key"],
        job.definition["worker_key"],
        query
      )

  defp matches_metadata?(id, state, queue, worker, query) do
    (is_nil(query.id) or id == query.id) and
      (is_nil(query.states) or state in query.states) and
      (is_nil(query.queues) or queue in query.queues) and
      (is_nil(query.workers) or worker in query.workers) and
      (is_nil(query.worker_contains) or String.contains?(worker, query.worker_contains))
  end

  defp key(job), do: {job.inserted_at, job.id}
end
