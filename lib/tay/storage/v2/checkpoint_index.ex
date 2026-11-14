defmodule Tay.Storage.V2.CheckpointIndex do
  @moduledoc "Persistent checkpoint roots, with authenticated references to immutable archive objects."
  alias Tay.Storage.{DiskIndex, Native, Record, Segment}
  alias Tay.Storage.V2.{Codec, RecoveryIndex, Reducer}

  @v2_roles [:root, :work, :schedules, :results, :expiry]
  @roles @v2_roles ++ [:history, :stats]
  @header_v2 <<"TAYI", 2, 0::size(59 * 8)>>
  @header_v3 <<"TAYI", 3, 0::size(59 * 8)>>
  @max_time Tay.Limits.int64_max()
  def roles, do: @roles

  def roles(2), do: @v2_roles
  def roles(3), do: @roles

  def valid?(%{format: format, bytes: bytes} = descriptor) when format in [2, 3] do
    roles = roles(format)
    keys = [:format, :bytes | roles] |> Enum.sort()

    Enum.sort(Map.keys(descriptor)) == keys and is_integer(bytes) and bytes >= 64 and
      Enum.all?(roles, fn role ->
        case DiskIndex.decode_root(descriptor[role]) do
          {:ok, nil} -> true
          {:ok, %{epoch: epoch, objects: _}} when byte_size(epoch) == 16 -> true
          _ -> false
        end
      end)
  end

  def valid?(_), do: false

  def begin(native, epoch, previous \\ nil) do
    with {:ok, _} <- Native.create_stage(native, :candidate, "RECOVERY"),
         {:ok, _} <- Native.write(native, 0, @header_v3),
         {:ok, roots} <- roots(previous) do
      {:ok, %{native: native, epoch: epoch, roots: roots, offset: 64}}
    end
  end

  def bootstrap(native, epoch, jobs, entries, auxiliary_entries, events, base) do
    sizes = Map.new(base, &{&1.id, {&1.bytes, &1.digest}})

    decorate = fn pointer ->
      {bytes, digest} = sizes[pointer["segment"]]

      pointer
      |> Map.put("epoch", {:bytes, epoch})
      |> Map.put("segment_bytes", bytes)
      |> Map.put("segment_digest", {:bytes, digest})
    end

    entries = Enum.map(entries, fn {id, pointer} -> {id, decorate.(pointer)} end)
    auxiliary = Enum.zip(auxiliary_entries, events)

    schedules =
      for {{_, pointer}, %{record_type: 13, data: data}} <- auxiliary,
          do: {data["schedule_id"], decorate.(pointer)}

    results =
      for {{_, pointer}, %{record_type: 10, data: data}} <- auxiliary,
          do: {data["job_id"], decorate.(pointer)}

    work = Enum.reject(entries, fn {id, _} -> terminal?(jobs[id]) end)

    expiry =
      for {id, pointer} <- entries, terminal?(jobs[id]), do: {expiry_key(jobs[id]), pointer}

    with {:ok, state} <- begin(native, epoch),
         {:ok, state} <- build_role(state, :root, entries),
         {:ok, state} <- build_role(state, :work, work),
         {:ok, state} <- build_role(state, :schedules, Enum.sort(schedules)),
         {:ok, state} <- build_role(state, :results, Enum.sort(results)),
         {:ok, state} <- build_role(state, :expiry, Enum.sort(expiry)),
         {:ok, state} <-
           build_role(
             state,
             :history,
             entries
             |> Enum.flat_map(fn {id, pointer} ->
               job = jobs[id]
               if terminal?(job), do: [{history_key(job), pointer}], else: []
             end)
             |> Enum.sort()
           ),
         {:ok, state} <- build_role(state, :stats, [{"summary", archive_summary(jobs)}]),
         do: finish(state)
  end

  defp build_role(state, role, entries) do
    write = fn offset, bytes ->
      case Native.write(state.native, offset, bytes) do
        {:ok, _} -> :ok
        error -> error
      end
    end

    with {:ok, root, offset} <- DiskIndex.build(entries, write, state.offset),
         do:
           {:ok,
            %{
              state
              | offset: offset,
                roots: Map.put(state.roots, role, DiskIndex.bind_epoch(root, state.epoch))
            }}
  end

  def archive_size(descriptor, epoch, segments) do
    {:ok, objects} = objects(descriptor)

    data =
      Map.new(
        for <<source::binary-size(16), 1, id::64, bytes::64>> <- objects,
            do: {{source, id}, bytes}
      )

    data =
      Enum.reduce(segments, data, fn segment, acc ->
        Map.put(acc, {epoch, segment.id}, segment.bytes)
      end)

    {Enum.sum(Map.values(data)), map_size(data)}
  end

  def finish(state) do
    with :ok <- Native.sync(state.native), :ok <- Native.close_write(state.native) do
      encoded =
        Map.new(state.roots, fn {role, root} ->
          {:ok, bytes} = DiskIndex.encode_root(root)
          {role, bytes}
        end)

      {:ok, Map.merge(encoded, %{format: 3, bytes: state.offset})}
    end
  end

  def roots(nil), do: {:ok, Map.new(@roles, &{&1, nil})}

  def roots(descriptor) do
    if valid?(descriptor) do
      {:ok,
       Map.new(@roles, fn role ->
         {role,
          if(Map.has_key?(descriptor, role),
            do: elem(DiskIndex.decode_root(descriptor[role]), 1),
            else: nil
          )}
       end)}
    else
      {:error, :checkpoint_roots}
    end
  end

  def objects(descriptor) do
    with {:ok, roots} <- roots(descriptor) do
      {:ok,
       roots |> Map.values() |> Enum.flat_map(&DiskIndex.objects/1) |> Enum.uniq() |> Enum.sort()}
    end
  end

  def count(descriptor, role \\ :root) do
    {:ok, root} = DiskIndex.decode_root(descriptor[role])
    if root, do: root.count, else: 0
  end

  def repack(state, max_epochs \\ 32) when is_integer(max_epochs) and max_epochs >= 0 do
    epochs =
      state.roots
      |> Map.values()
      |> Enum.flat_map(&DiskIndex.objects/1)
      |> Enum.flat_map(fn
        <<epoch::binary-size(16), 0, 0::128>> -> [epoch]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == state.epoch))
      |> Enum.sort()

    if length(epochs) > max_epochs do
      source = hd(epochs)

      write = fn offset, bytes ->
        with {:ok, _} <- Native.write(state.native, offset, bytes), do: :ok
      end

      Enum.reduce_while(@roles, {:ok, state, 64 * 1_048_576}, fn role, {:ok, acc, budget} ->
        case DiskIndex.repack(
               reader(acc.native, acc.epoch, :candidate),
               write,
               acc.roots[role],
               source,
               acc.offset,
               acc.epoch,
               budget
             ) do
          {:ok, root, offset, left} ->
            {:cont, {:ok, %{acc | offset: offset, roots: Map.put(acc.roots, role, root)}, left}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, next, _} -> {:ok, next}
        error -> error
      end
    else
      {:ok, state}
    end
  end

  def change(state, role, changes) when role in @roles do
    write = fn offset, bytes ->
      case Native.write(state.native, offset, bytes) do
        {:ok, _} -> :ok
        error -> error
      end
    end

    with {:ok, root, offset} <-
           DiskIndex.update(
             reader(state.native, state.epoch, :candidate),
             write,
             state.roots[role],
             changes,
             state.offset,
             state.epoch
           ) do
      {:ok, %{state | roots: Map.put(state.roots, role, root), offset: offset}}
    end
  end

  def put_job(state, id, pointer, job) do
    read = reader(state.native, state.epoch, :candidate)

    with previous <- DiskIndex.fetch(read, state.roots.root, id),
         {:ok, state} <- remove_expiry(state, previous),
         {:ok, state} <- change(state, :root, [{id, {:put, pointer}}]),
         {:ok, state} <-
           change(state, :work, [{id, if(terminal?(job), do: :delete, else: {:put, pointer})}]),
         {:ok, state} <-
           if(terminal?(job),
             do: change(state, :expiry, [{expiry_key(job), {:put, pointer}}]),
             else: {:ok, state}
           ) do
      {:ok, state}
    end
  end

  def apply_changes(state, puts, expired) do
    read = reader(state.native, state.epoch, :candidate)

    prior_ids =
      Enum.map(puts, &elem(&1, 0)) ++ Enum.map(expired, &elem(&1, 0))

    with {:ok, previous} <-
           Enum.reduce_while(prior_ids, {:ok, %{}}, fn id, {:ok, jobs} ->
             case DiskIndex.fetch(read, state.roots.root, id) do
               {:ok, %{"summary" => _} = pointer} ->
                 case summary(pointer) do
                   {:ok, job} -> {:cont, {:ok, Map.put(jobs, id, job)}}
                   error -> {:halt, error}
                 end

               {:ok, _} ->
                 {:cont, {:ok, jobs}}

               :not_found ->
                 {:cont, {:ok, jobs}}

               error ->
                 {:halt, error}
             end
           end),
         old_expiry = Enum.map(previous, fn {_, job} -> {expiry_key(job), :delete} end),
         deletes = Enum.map(expired, fn {id, _job} -> {id, :delete} end),
         root_changes =
           deletes ++ Enum.map(puts, fn {id, pointer, _} -> {id, {:put, pointer}} end),
         work_changes =
           deletes ++
             Enum.map(puts, fn {id, pointer, job} ->
               {id, if(terminal?(job), do: :delete, else: {:put, pointer})}
             end),
         expiry_changes =
           old_expiry ++
             Enum.map(expired, fn {_, job} -> {expiry_key(job), :delete} end) ++
             for(
               {_id, pointer, job} <- puts,
               terminal?(job),
               do: {expiry_key(job), {:put, pointer}}
             ),
         history_changes =
           Enum.map(previous, fn {_, job} -> {history_key(job), :delete} end) ++
             Enum.map(expired, fn {_, job} -> {history_key(job), :delete} end) ++
             for(
               {_id, pointer, job} <- puts,
               terminal?(job),
               do: {history_key(job), {:put, pointer}}
             ),
         {:ok, state} <- change(state, :root, root_changes),
         {:ok, state} <- change(state, :work, work_changes),
         {:ok, state} <- change(state, :expiry, expiry_changes),
         {:ok, state} <- change(state, :history, history_changes),
         {:ok, state} <- update_archive_summary(state, previous, puts),
         do: change(state, :results, deletes)
  end

  def archive_summary(native, descriptor, epoch, scope \\ :epoch) do
    with {:ok, roots} <- roots(descriptor),
         {:ok, value} <- DiskIndex.fetch(reader(native, epoch, scope), roots.stats, "summary"),
         do: decode_archive_summary(value)
  end

  def history_page(native, descriptor, epoch, after_key, limit, scope \\ :epoch) do
    with {:ok, roots} <- roots(descriptor),
         {:ok, page} <-
           DiskIndex.page(reader(native, epoch, scope), roots.history, after_key, limit) do
      Enum.reduce_while(page, {:ok, []}, fn {key, pointer}, {:ok, acc} ->
        case summary(pointer) do
          {:ok, job} -> {:cont, {:ok, [{key, job} | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
        error -> error
      end
    end
  end

  def history_candidates(native, descriptor, epoch, query, scope \\ :epoch) do
    with {:ok, summary} <- archive_summary(native, descriptor, epoch, scope) do
      cond do
        not is_nil(query.id) ->
          case fetch(native, descriptor, epoch, query.id, scope) do
            {:ok, job} ->
              jobs = if history_match?(job, query), do: [job], else: []
              {:ok, %{jobs: jobs, total_count: length(jobs)}}

            :not_found ->
              {:ok, %{jobs: [], total_count: 0}}

            error ->
              error
          end

        is_nil(query.worker_contains) and
            (is_nil(query.position) or match?({:after, _, _}, query.position)) ->
          cursor =
            case query.position do
              nil -> nil
              {:after, {at, id}, _} -> history_key(%{inserted_at: at, id: id})
            end

          with {:ok, jobs} <-
                 history_forward(native, descriptor, epoch, cursor, query, query.limit, [], scope) do
            {:ok, %{jobs: jobs, total_count: history_count(summary, query)}}
          end

        true ->
          with {:ok, entries} <- history_entries(native, descriptor, epoch, nil, [], scope) do
            matching =
              entries |> Enum.map(&elem(&1, 1)) |> Enum.filter(&history_match?(&1, query))

            selected =
              case query.position do
                nil ->
                  matching

                :last ->
                  Enum.reverse(matching)

                {:after, {at, id}, _} ->
                  matching
                  |> Enum.drop_while(&({&1.inserted_at, &1.id} != {at, id}))
                  |> Enum.drop(1)

                {:before, {at, id}, _} ->
                  matching
                  |> Enum.take_while(&({&1.inserted_at, &1.id} != {at, id}))
                  |> Enum.reverse()
              end
              |> Enum.take(query.limit)

            {:ok, %{jobs: selected, total_count: length(matching)}}
          end
      end
    end
  end

  defp history_forward(native, descriptor, epoch, cursor, query, limit, acc, scope) do
    with {:ok, page} <- history_page(native, descriptor, epoch, cursor, 128, scope) do
      next =
        page
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&history_match?(&1, query))
        |> then(&(acc ++ &1))

      cond do
        length(next) >= limit ->
          {:ok, Enum.take(next, limit)}

        length(page) < 128 ->
          {:ok, next}

        true ->
          history_forward(
            native,
            descriptor,
            epoch,
            elem(List.last(page), 0),
            query,
            limit,
            next,
            scope
          )
      end
    end
  end

  defp history_count(summary, query) do
    Enum.reduce(summary.facets, 0, fn {{queue, state, worker}, count}, total ->
      if (is_nil(query.states) or state in query.states) and
           (is_nil(query.queues) or queue in query.queues) and
           (is_nil(query.workers) or worker in query.workers),
         do: total + count,
         else: total
    end)
  end

  defp history_entries(native, descriptor, epoch, cursor, acc, scope) do
    with {:ok, page} <- history_page(native, descriptor, epoch, cursor, 256, scope) do
      next = acc ++ page

      if length(page) == 256,
        do: history_entries(native, descriptor, epoch, elem(List.last(page), 0), next, scope),
        else: {:ok, next}
    end
  end

  defp history_match?(job, query) do
    (is_nil(query.id) or job.id == query.id) and
      (is_nil(query.states) or job.state in query.states) and
      (is_nil(query.queues) or job.definition["queue_key"] in query.queues) and
      (is_nil(query.workers) or job.definition["worker_key"] in query.workers) and
      (is_nil(query.worker_contains) or
         String.contains?(job.definition["worker_key"], query.worker_contains))
  end

  def expired(native, descriptor, epoch, retention, now, jobs) do
    with :ok <- Tay.Storage.V2.Retention.validate(retention), {:ok, roots} <- roots(descriptor) do
      cutoff =
        case retention do
          :infinity ->
            -1

          {_unit, 0} ->
            @max_time

          finite ->
            {:ok, duration} = Tay.Storage.V2.Retention.duration(finite)
            now - duration
        end

      with {:ok, expired} <-
             expiry_pages(reader(native, epoch, :epoch), roots.expiry, nil, cutoff, jobs, %{}) do
        Enum.reduce_while(jobs, {:ok, expired}, fn {id, job}, {:ok, acc} ->
          case Tay.Storage.V2.Snapshot.classify(job, retention, now) do
            {:ok, :expire} -> {:cont, {:ok, Map.put(acc, id, job)}}
            {:ok, :retain} -> {:cont, {:ok, acc}}
            error -> {:halt, error}
          end
        end)
      end
    end
  end

  defp expiry_pages(_read, _root, _cursor, cutoff, _jobs, expired) when cutoff < 0,
    do: {:ok, expired}

  defp expiry_pages(read, root, cursor, cutoff, jobs, expired) do
    with {:ok, page} <- DiskIndex.page(read, root, cursor, 128),
         {:ok, expired, continue} <-
           Enum.reduce_while(page, {:ok, expired, true}, fn
             {<<at::64, id::binary-size(16)>>, pointer}, {:ok, acc, true} when at <= cutoff ->
               with {:ok, summary} <- summary(pointer),
                    true <-
                      (summary.id == id and summary.terminal_at == at) ||
                        {:error, :checkpoint_expiry_key} do
                 job = Map.get(jobs, id, summary)

                 if terminal?(job) and job.terminal_at <= cutoff,
                   do: {:cont, {:ok, Map.put(acc, id, job), true}},
                   else: {:cont, {:ok, acc, true}}
               else
                 error -> {:halt, error}
               end

             {<<_::64, _::binary-size(16)>>, _}, {:ok, acc, true} ->
               {:halt, {:ok, acc, false}}

             _, _ ->
               {:halt, {:error, :checkpoint_expiry_key}}
           end) do
      if continue and length(page) == 128,
        do: expiry_pages(read, root, elem(List.last(page), 0), cutoff, jobs, expired),
        else: {:ok, expired}
    end
  end

  def affected(%{record_type: 8, payload_schema_version: 1, payload: payload}, limits) do
    with {:ok, mutation} <- Codec.decode_mutation(payload, limits),
         do: {:ok, %{job: mutation.job_id, job_changed: true, result: nil, schedule: nil}}
  end

  def affected(%{record_type: type, payload_schema_version: 2, payload: payload}, limits) do
    with {:ok, event, _} <- Tay.Event.decode_payload(type, 2, payload, limits) do
      {:ok,
       %{
         job: event.data["job_id"],
         job_changed: type == 14,
         result: if(type in [10, 14], do: event.data["job_id"]),
         schedule: event.data["schedule_id"]
       }}
    end
  end

  def affected(_, _), do: {:error, :checkpoint_tail_profile}

  def prepare_record(native, descriptor, epoch, scope, candidate, affected) do
    with {:ok, candidate} <- ensure_job(native, descriptor, epoch, scope, candidate, affected.job),
         do: ensure_result(native, descriptor, epoch, scope, candidate, affected.result)
  end

  defp ensure_job(_native, _descriptor, _epoch, _scope, candidate, nil), do: {:ok, candidate}

  defp ensure_job(native, descriptor, epoch, scope, candidate, id) do
    case Map.get(candidate.jobs, id) do
      nil ->
        case fetch(native, descriptor, epoch, id, scope) do
          {:ok, job} -> Reducer.insert_snapshot(candidate, job)
          :not_found -> {:ok, candidate}
          error -> error
        end

      %{cold: true} ->
        with {:ok, job} <- fetch(native, descriptor, epoch, id, scope),
             do: Reducer.insert_snapshot(%{candidate | jobs: Map.delete(candidate.jobs, id)}, job)

      _ ->
        {:ok, candidate}
    end
  end

  defp ensure_result(_native, _descriptor, _epoch, _scope, candidate, nil), do: {:ok, candidate}

  defp ensure_result(native, descriptor, epoch, scope, candidate, id) do
    if Map.has_key?(candidate.results, id) do
      {:ok, candidate}
    else
      case result(native, descriptor, epoch, id, scope) do
        {:ok, result} ->
          bytes = Tay.State.Memory.result_bytes(result)

          with :ok <- Tay.State.Memory.check(candidate.limits, candidate.bytes + bytes),
               do:
                 {:ok,
                  %{
                    candidate
                    | results: Map.put(candidate.results, id, result),
                      bytes: candidate.bytes + bytes,
                      auxiliary_bytes: candidate.auxiliary_bytes + bytes
                  }}

        :not_found ->
          {:ok, candidate}

        error ->
          error
      end
    end
  end

  def result(native, descriptor, epoch, id, scope \\ :epoch) do
    with {:ok, roots} <- roots(descriptor),
         {:ok, pointer} <- DiskIndex.fetch(reader(native, epoch, scope), roots.results, id),
         {:ok, %{record_type: 10, payload_schema_version: 2, payload: payload}} <-
           read_record(native, epoch, scope, pointer),
         {:ok, event, _} <- Tay.Event.decode_payload(10, 2, payload, Tay.Event.Value.defaults()),
         true <- event.data["job_id"] == id || {:error, :checkpoint_result_id} do
      {:ok,
       %{
         value: event.data["result"],
         recorded_at: event.data["at"],
         job_revision: event.data["expected_revision"]
       }}
    end
  end

  def delete_job(state, id, pointer) do
    with {:ok, state} <- remove_expiry(state, {:ok, pointer}),
         {:ok, state} <- change(state, :root, [{id, :delete}]),
         {:ok, state} <- change(state, :work, [{id, :delete}]),
         do: change(state, :results, [{id, :delete}])
  end

  defp remove_expiry(state, :not_found), do: {:ok, state}

  defp remove_expiry(state, {:ok, %{"summary" => _} = pointer}) do
    with {:ok, summary} <- summary(pointer),
         do: change(state, :expiry, [{expiry_key(summary), :delete}])
  end

  defp remove_expiry(state, {:ok, _}), do: {:ok, state}
  defp remove_expiry(_state, error), do: error
  defp expiry_key(job), do: <<job.terminal_at::64, job.id::binary-size(16)>>

  defp history_key(job) do
    inverse_id = :crypto.exor(job.id, :binary.copy(<<255>>, 16))
    <<@max_time - job.inserted_at::64, inverse_id::binary-size(16)>>
  end

  defp update_archive_summary(state, previous, puts) do
    current =
      case DiskIndex.fetch(
             reader(state.native, state.epoch, :candidate),
             state.roots.stats,
             "summary"
           ) do
        {:ok, value} -> elem(decode_archive_summary(value), 1)
        :not_found -> empty_archive_summary()
      end

    next =
      previous
      |> Map.values()
      |> Enum.reduce(current, &archive_adjust(&2, &1, -1))
      |> then(fn summary ->
        Enum.reduce(puts, summary, fn {_id, _pointer, job}, acc ->
          archive_adjust(acc, job, 1)
        end)
      end)

    change(state, :stats, [{"summary", {:put, encode_archive_summary(next)}}])
  end

  defp archive_summary(jobs) do
    jobs
    |> Enum.reduce(empty_archive_summary(), fn {_, job}, acc ->
      if terminal?(job), do: archive_adjust(acc, job, 1), else: acc
    end)
    |> encode_archive_summary()
  end

  defp empty_archive_summary,
    do: %{
      count: 0,
      bytes: 0,
      definition_bytes: 0,
      bound_bytes: 0,
      states: %{},
      facets: %{},
      buckets: %{}
    }

  defp archive_adjust(summary, job, sign) do
    if terminal?(job) do
      queue = job.definition["queue_key"]
      worker = job.definition["worker_key"]
      definition = Map.get(job, :definition_size, byte_size(job.definition_bytes))
      bucket = div(job.terminal_at, 3_600_000)

      summary
      |> Map.update!(:count, &(&1 + sign))
      |> Map.update!(:bytes, &(&1 + sign * archive_charge(job)))
      |> Map.update!(:definition_bytes, &(&1 + sign * definition))
      |> Map.update!(:bound_bytes, &(&1 + sign * (definition + 512)))
      |> update_counter(:states, job.state, sign)
      |> update_counter(:facets, {queue, job.state, worker}, sign)
      |> update_bucket(bucket, sign, definition + 512)
    else
      summary
    end
  end

  defp update_counter(summary, field, key, amount) do
    values = Map.update(Map.fetch!(summary, field), key, amount, &(&1 + amount))
    values = if values[key] == 0, do: Map.delete(values, key), else: values
    Map.put(summary, field, values)
  end

  defp update_bucket(summary, key, sign, bytes) do
    old = Map.get(summary.buckets, key, %{count: 0, bytes: 0})
    next = %{count: old.count + sign, bytes: old.bytes + sign * bytes}

    buckets =
      if next.count == 0,
        do: Map.delete(summary.buckets, key),
        else: Map.put(summary.buckets, key, next)

    %{summary | buckets: buckets}
  end

  defp archive_charge(%{charge: %{bytes: bytes}}), do: bytes

  defp archive_charge(job) do
    {:ok, candidate} = Reducer.insert_snapshot(Reducer.candidate(), job)
    candidate.jobs[job.id].charge.bytes
  end

  defp encode_archive_summary(summary) do
    %{
      "version" => 1,
      "count" => summary.count,
      "bytes" => summary.bytes,
      "definition_bytes" => summary.definition_bytes,
      "bound_bytes" => summary.bound_bytes,
      "states" => Map.new(summary.states, fn {key, value} -> {Atom.to_string(key), value} end),
      "facets" =>
        summary.facets
        |> Enum.sort_by(fn {{queue, state, worker}, _} -> {queue, state, worker} end)
        |> Enum.map(fn {{queue, state, worker}, count} ->
          %{
            "queue" => queue,
            "state" => Atom.to_string(state),
            "worker" => worker,
            "count" => count
          }
        end),
      "buckets" =>
        summary.buckets
        |> Enum.sort()
        |> Enum.map(fn {hour, bucket} -> [hour, bucket.count, bucket.bytes] end)
    }
  end

  defp decode_archive_summary(%{
         "version" => 1,
         "count" => count,
         "bytes" => bytes,
         "definition_bytes" => definition_bytes,
         "bound_bytes" => bound_bytes,
         "states" => states,
         "facets" => facets,
         "buckets" => buckets
       }) do
    known = %{"completed" => :completed, "cancelled" => :cancelled, "discarded" => :discarded}

    with true <- is_integer(count) and count >= 0 and is_integer(bytes) and bytes >= 0,
         true <- is_integer(definition_bytes) and definition_bytes >= 0,
         true <- is_integer(bound_bytes) and bound_bytes >= 0,
         true <- is_map(states) and is_list(facets) and is_list(buckets) do
      {:ok,
       %{
         count: count,
         bytes: bytes,
         definition_bytes: definition_bytes,
         bound_bytes: bound_bytes,
         states: Map.new(states, fn {key, value} -> {Map.fetch!(known, key), value} end),
         facets:
           Map.new(facets, fn %{
                                "queue" => queue,
                                "state" => state,
                                "worker" => worker,
                                "count" => n
                              } ->
             {{queue, Map.fetch!(known, state), worker}, n}
           end),
         buckets:
           Map.new(buckets, fn [hour, bucket_count, value] ->
             {hour, %{count: bucket_count, bytes: value}}
           end)
       }}
    else
      _ -> {:error, :checkpoint_archive_summary}
    end
  rescue
    _ -> {:error, :checkpoint_archive_summary}
  end

  defp decode_archive_summary(_), do: {:error, :checkpoint_archive_summary}
  defp terminal?(job), do: job.state in [:completed, :cancelled, :discarded]

  def pointer(epoch, segment, offset, record, job \\ nil) do
    pointer =
      if job,
        do: RecoveryIndex.location(segment, offset, record, job),
        else: RecoveryIndex.location(segment, offset, record)

    Map.put(pointer, "epoch", {:bytes, epoch})
  end

  def summary(%{
        "summary" => %{
          "snapshot" => {:bytes, bytes},
          "definition_bytes" => size,
          "charge" => charge
        }
      })
      when is_integer(size) and size > 0 and is_integer(charge) and charge > 0 do
    with {:ok, job} <- Codec.decode_snapshot(bytes),
         true <- terminal?(job) || {:error, :checkpoint_summary} do
      {:ok,
       job
       |> Map.put(:cold, true)
       |> Map.put(:definition_size, size)
       |> Map.put(:charge, %{bytes: charge, base_bytes: charge})}
    end
  end

  def summary(_), do: {:error, :checkpoint_summary}

  def fetch(native, descriptor, epoch, id, scope \\ :epoch) do
    with {:ok, roots} <- roots(descriptor),
         {:ok, pointer} <- DiskIndex.fetch(reader(native, epoch, scope), roots.root, id),
         {:ok, record} <- read_record(native, epoch, scope, pointer),
         true <-
           (record.record_type == 7 and record.payload_schema_version == 1) ||
             {:error, :checkpoint_record_type},
         {:ok, job} <- Codec.decode_snapshot(record.payload),
         true <- job.id == id || {:error, :checkpoint_job_id},
         true <-
           pointer["summary"] ==
             RecoveryIndex.location(pointer["segment"], pointer["offset"], record, job)["summary"] ||
             {:error, :checkpoint_summary_mismatch} do
      case summary(pointer) do
        {:ok, archived} -> {:ok, Map.put(job, :charge, archived.charge)}
        _ -> {:ok, job}
      end
    end
  end

  def read_record(native, epoch, scope, %{
        "epoch" => {:bytes, source},
        "segment" => segment,
        "offset" => offset,
        "bytes" => bytes,
        "sequence" => sequence,
        "digest" => {:bytes, digest}
      })
      when byte_size(source) == 16 and is_integer(segment) and segment > 0 and
             is_integer(offset) and offset >= 44 and bytes in 28..16_777_244 and
             byte_size(digest) == 32 do
    {:ok, name} = Segment.filename(segment)
    segment_scope = if scope == :candidate, do: :candidate_segments, else: :segments

    with_file(native, epoch, source, segment_scope, name, fn identity ->
      with true <- offset + bytes <= identity.size || {:error, :checkpoint_record_range},
           {:ok, bytes} <- Native.read(native, offset, bytes),
           {:ok, record, <<>>} <- Record.decode(bytes),
           true <- record.sequence == sequence || {:error, :checkpoint_record_sequence},
           true <-
             :crypto.hash(:sha256, record.payload) == digest ||
               {:error, :checkpoint_record_digest},
           do: {:ok, record}
    end)
  end

  def read_record(_, _, _, _), do: {:error, :checkpoint_pointer}

  def reader(native, epoch, scope) do
    fn source, offset, bytes ->
      source = source || epoch

      with_file(native, epoch, source, scope, "RECOVERY", fn identity ->
        with true <-
               (offset >= 64 and offset + bytes <= identity.size) ||
                 {:error, :checkpoint_page_range},
             do: Native.read(native, offset, bytes)
      end)
    end
  end

  defp with_file(native, epoch, source, scope, name, fun) do
    opened =
      if epoch == source and scope in [:candidate, :candidate_segments],
        do: Native.open_read(native, scope, name),
        else:
          Native.open_epoch_read(
            native,
            source,
            if(scope in [:segments, :candidate_segments], do: :segments, else: :epoch),
            name
          )

    with {:ok, identity} <- opened do
      result = fun.(identity)
      close = Native.close_read(native)
      if close == :ok, do: result, else: close
    end
  end

  def verify_roots(native, descriptor, epoch, scope \\ :epoch) do
    with true <- valid?(descriptor) || {:error, :checkpoint_descriptor},
         :ok <-
           with_file(native, epoch, epoch, scope, "RECOVERY", fn identity ->
             with true <- identity.size == descriptor.bytes || {:error, :checkpoint_index_size},
                  {:ok, header} <- Native.read(native, 0, 64),
                  true <-
                    header == if(descriptor.format == 2, do: @header_v2, else: @header_v3) ||
                      {:error, :checkpoint_index_header},
                  do: :ok
           end),
         {:ok, roots} <- roots(descriptor) do
      Enum.reduce_while(roots, :ok, fn {_role, root}, :ok ->
        case if(root,
               do: DiskIndex.inspect_node(reader(native, epoch, scope), root),
               else: {:ok, nil}
             ) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  def reduce(native, descriptor, epoch, role, initial, reducer, scope \\ :epoch) do
    with {:ok, roots} <- roots(descriptor),
         do: DiskIndex.reduce(reader(native, epoch, scope), roots[role], initial, reducer)
  end

  def load(native, descriptor, epoch, limits, value_limits, mode \\ :all, scope \\ :epoch) do
    with :ok <- verify_roots(native, descriptor, epoch, scope),
         true <-
           count(descriptor) == count(descriptor, :work) + count(descriptor, :expiry) ||
             {:error, :checkpoint_partition},
         :ok <-
           if(mode == :scrub, do: verify_partitions(native, descriptor, epoch, scope), else: :ok),
         {:ok, candidate} <-
           reduce(
             native,
             descriptor,
             epoch,
             if(mode in [:work, :runtime], do: :work, else: :root),
             Reducer.candidate(limits, value_limits),
             fn id, pointer, candidate ->
               value =
                 if Map.has_key?(pointer, "summary") and mode != :scrub,
                   do: summary(pointer),
                   else: fetch(native, descriptor, epoch, id, scope)

               with {:ok, job} <- value,
                    true <- job.id == id || {:error, :checkpoint_job_id},
                    true <- (mode != :work or not terminal?(job)) || {:error, :checkpoint_work},
                    {:ok, next} <- Reducer.insert_snapshot(candidate, job) do
                 job = if Map.has_key?(job, :cold), do: job, else: next.jobs[id]
                 {:ok, put_in(next.jobs[id], job)}
               end
             end,
             scope
           ),
         {:ok, candidate} <-
           load_auxiliary(native, descriptor, epoch, :schedules, candidate, scope),
         {:ok, candidate} <-
           if(mode in [:work, :runtime],
             do: {:ok, candidate},
             else: load_results(native, descriptor, epoch, candidate, scope, mode)
           ) do
      {:ok, candidate}
    end
  end

  defp verify_partitions(native, descriptor, epoch, scope) do
    {:ok, roots} = roots(descriptor)
    read = reader(native, epoch, scope)

    with {:ok, :ok} <-
           DiskIndex.reduce(read, roots.root, :ok, fn id, pointer, :ok ->
             with {:ok, role, key} <- partition_entry(id, pointer),
                  {:ok, ^pointer} <- DiskIndex.fetch(read, roots[role], key),
                  do: {:ok, :ok}
           end),
         {:ok, :ok} <-
           DiskIndex.reduce(read, roots.expiry, :ok, fn key, pointer, :ok ->
             with {:ok, job} <- summary(pointer),
                  true <- key == expiry_key(job) || {:error, :checkpoint_expiry},
                  {:ok, ^pointer} <- DiskIndex.fetch(read, roots.root, job.id),
                  do: {:ok, :ok}
           end),
         do: :ok
  end

  defp partition_entry(id, %{"summary" => _} = pointer) do
    with {:ok, job} <- summary(pointer),
         true <- (job.id == id and terminal?(job)) || {:error, :checkpoint_expiry},
         do: {:ok, :expiry, expiry_key(job)}
  end

  defp partition_entry(id, _pointer), do: {:ok, :work, id}

  def load_changed(native, descriptor, epoch, limits, value_limits, ids, results, scope) do
    with :ok <- verify_new_pages(native, descriptor, epoch, scope),
         {:ok, candidate} <- load(native, descriptor, epoch, limits, value_limits, :work, scope),
         {:ok, candidate} <-
           Enum.reduce_while(ids, {:ok, candidate}, fn {id, expected}, {:ok, acc} ->
             case ensure_expected_job(native, descriptor, epoch, scope, acc, id, expected) do
               {:ok, next} -> {:cont, {:ok, next}}
               error -> {:halt, error}
             end
           end),
         {:ok, candidate} <-
           Enum.reduce_while(results, {:ok, candidate}, fn id, {:ok, acc} ->
             case ensure_result(native, descriptor, epoch, scope, acc, id) do
               {:ok, next} -> {:cont, {:ok, next}}
               error -> {:halt, error}
             end
           end),
         true <-
           count(descriptor) == count(descriptor, :work) + count(descriptor, :expiry) ||
             {:error, :checkpoint_partition} do
      {:ok, candidate}
    end
  end

  defp ensure_expected_job(native, descriptor, epoch, scope, candidate, id, %{cold: true}) do
    with {:ok, roots} <- roots(descriptor),
         {:ok, pointer} <- DiskIndex.fetch(reader(native, epoch, scope), roots.root, id),
         {:ok, job} <- summary(pointer),
         true <- job.id == id || {:error, :checkpoint_job_id},
         {:ok, next} <- Reducer.insert_snapshot(candidate, job),
         do: {:ok, put_in(next.jobs[id], job)}
  end

  defp ensure_expected_job(native, descriptor, epoch, scope, candidate, id, _expected),
    do: ensure_job(native, descriptor, epoch, scope, candidate, id)

  def verify_new_pages(native, descriptor, epoch, scope) do
    with {:ok, roots} <- roots(descriptor) do
      Enum.reduce_while(roots, :ok, fn {_role, root}, :ok ->
        case verify_new_node(reader(native, epoch, scope), root, epoch) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp verify_new_node(_read, nil, _epoch), do: :ok
  defp verify_new_node(_read, %{epoch: source}, epoch) when source != epoch, do: :ok

  defp verify_new_node(read, root, epoch) do
    with {:ok, node} <- DiskIndex.inspect_node(read, root) do
      case node do
        {:leaf, _} ->
          :ok

        {:children, children} ->
          Enum.reduce_while(children, :ok, fn child, :ok ->
            case verify_new_node(read, child, epoch) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
      end
    end
  end

  def scrub_objects(native, descriptor, epoch, store_id, scope \\ :epoch) do
    with :ok <- verify_roots(native, descriptor, epoch, scope),
         {:ok, files} <-
           Enum.reduce_while(@roles -- [:work, :expiry, :stats], {:ok, %{}}, fn role,
                                                                                {:ok, acc} ->
             result =
               reduce(
                 native,
                 descriptor,
                 epoch,
                 role,
                 acc,
                 fn _key, pointer, files ->
                   with %{
                          "epoch" => {:bytes, source},
                          "segment" => id,
                          "segment_bytes" => bytes,
                          "segment_digest" => {:bytes, digest}
                        } <- pointer,
                        true <-
                          (is_nil(files[{source, id}]) or files[{source, id}] == {bytes, digest}) ||
                            {:error, :checkpoint_segment_conflict} do
                     {:ok, Map.put(files, {source, id}, {bytes, digest})}
                   else
                     _ -> {:error, :checkpoint_segment_inventory}
                   end
                 end,
                 scope
               )

             case result do
               {:ok, files} -> {:cont, {:ok, files}}
               error -> {:halt, error}
             end
           end) do
      Enum.reduce_while(files, :ok, fn {{source, id}, {bytes, digest}}, :ok ->
        {:ok, name} = Segment.filename(id)
        segment_scope = if scope == :candidate, do: :candidate_segments, else: :segments

        result =
          with_file(native, epoch, source, segment_scope, name, fn identity ->
            with true <- identity.size == bytes || {:error, :checkpoint_segment_size},
                 {:ok, summary} <-
                   Tay.Storage.BufferedRead.with_reader(
                     &Native.read(native, &1, &2),
                     bytes,
                     fn read ->
                       Segment.scan(read, bytes,
                         id: id,
                         store_id: store_id,
                         highest: false,
                         sha256: true
                       )
                     end
                   ),
                 true <- summary.digest == digest || {:error, :checkpoint_segment_digest},
                 do: :ok
          end)

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp load_results(native, descriptor, epoch, candidate, scope, _),
    do: load_auxiliary(native, descriptor, epoch, :results, candidate, scope)

  defp load_auxiliary(native, descriptor, epoch, role, candidate, scope) do
    reduce(
      native,
      descriptor,
      epoch,
      role,
      candidate,
      fn key, pointer, candidate ->
        with {:ok, record} <- read_record(native, epoch, scope, pointer),
             true <-
               (role == :schedules and record.record_type == 13 and
                  record.payload_schema_version == 2) or
                 (role == :results and record.record_type == 10 and
                    record.payload_schema_version == 2) or {:error, :auxiliary_type},
             {:ok, event, _} <-
               Tay.Event.decode_payload(
                 record.record_type,
                 record.payload_schema_version,
                 record.payload,
                 candidate.value_limits
               ),
             true <-
               key == event.data[if(role == :schedules, do: "schedule_id", else: "job_id")] or
                 {:error, :auxiliary_key},
             do: Reducer.apply_event(candidate, event, %{sequence: record.sequence})
      end,
      scope
    )
  end
end
