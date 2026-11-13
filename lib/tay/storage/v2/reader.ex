defmodule Tay.Storage.V2.Reader do
  require Tay.Event.V2

  @moduledoc """
  Store-v2 recovery through the lock-owning native session. No path is opened
  through File; every read is pinned, positional, bounded and revalidated.
  """

  alias Tay.Event
  alias Tay.Storage.{BufferedRead, Native, Reader, Segment}
  alias Tay.Storage.V2.{Authority, Codec, Reducer, RecoveryIndex}

  @max_metadata 16_777_216

  def recover(native, candidate, options \\ []) do
    with :ok <- Native.check(native),
         {:ok, root} <- Native.list(native, :root),
         :ok <- root?(root),
         {:ok, marker} <- metadata(native, :root, root, "STORE-V2", 28),
         {:ok, current} <- metadata(native, :root, root, "CURRENT", 76),
         {:ok, pointer} <- Authority.decode_current(current),
         :ok <- maybe_select(native, pointer.epoch_id, options),
         {:ok, epoch_entries} <- Native.list(native, :epoch),
         :ok <- epoch?(epoch_entries),
         {:ok, manifest_bytes} <-
           metadata(native, :epoch, epoch_entries, "MANIFEST", @max_metadata),
         {:ok, manifest} <- Authority.verify_selection(marker, current, manifest_bytes),
         :ok <- index_topology(epoch_entries, manifest),
         {:ok, segment_entries} <- Native.list(native, :segments),
         {:ok, classified} <- Reader.classify_entries(segment_entries, :segments),
         true <- classified.unrelated == [] || {:error, :unexpected_epoch_segment_entry},
         {:ok, result} <-
           runtime_replay(native, candidate, classified.canonical, manifest, options),
         :ok <- revalidate_root(native, root, marker, current),
         :ok <- Native.check(native) do
      {:ok,
       Map.merge(result, %{
         store_id: manifest.store_id,
         epoch_id: pointer.epoch_id,
         manifest: manifest,
         marker: marker,
         current: current,
         root_entries: root,
         segment_entries: segment_entries,
         staging_count: length(classified.staging),
         ignored_count: length(classified.unrelated)
       })}
    end
  end

  @doc false
  def recover_physical(native, options \\ []) do
    with :ok <- Native.check(native),
         {:ok, root} <- Native.list(native, :root),
         :ok <- root?(root),
         {:ok, marker} <- metadata(native, :root, root, "STORE-V2", 28),
         {:ok, current} <- metadata(native, :root, root, "CURRENT", 76),
         {:ok, pointer} <- Authority.decode_current(current),
         :ok <- maybe_select(native, pointer.epoch_id, options),
         {:ok, epoch_entries} <- Native.list(native, :epoch),
         :ok <- epoch?(epoch_entries),
         {:ok, manifest_bytes} <-
           metadata(native, :epoch, epoch_entries, "MANIFEST", @max_metadata),
         {:ok, manifest} <- Authority.verify_selection(marker, current, manifest_bytes),
         :ok <- index_topology(epoch_entries, manifest),
         {:ok, segment_entries} <- Native.list(native, :segments),
         {:ok, classified} <- Reader.classify_entries(segment_entries, :segments),
         true <- classified.unrelated == [] || {:error, :unexpected_epoch_segment_entry},
         {:ok, result} <- physical_replay(native, classified.canonical, manifest),
         :ok <- revalidate_root(native, root, marker, current),
         :ok <- Native.check(native) do
      {:ok,
       Map.merge(result, %{
         store_id: manifest.store_id,
         epoch_id: pointer.epoch_id,
         manifest: manifest,
         current: current
       })}
    end
  end

  @doc false
  def reduce_physical(native, accumulator, reducer) when is_function(reducer, 3) do
    with {:ok, recovered} <- recover_physical(native, selected: true) do
      Enum.reduce_while(recovered.store.segments, {:ok, accumulator}, fn segment, {:ok, acc} ->
        {:ok, name} = Segment.filename(segment.id)
        entry = Map.put(segment.identity, :name, name)

        result =
          with_file(native, :segments, entry, fn ->
            BufferedRead.with_reader(&Native.read(native, &1, &2), entry.size, fn read ->
              Segment.reduce(read, entry.size, acc, reducer,
                id: segment.id,
                store_id: recovered.store_id,
                highest: segment.id == recovered.highest.id
              )
            end)
          end)

        case result do
          {:ok, _, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def recover_frozen(native, candidate, epoch_id, exclude_segment_id, options \\ [])
      when is_binary(epoch_id) and is_integer(exclude_segment_id) and exclude_segment_id > 0 do
    with :ok <- Native.check(native),
         {:ok, root} <- Native.list(native, :root),
         :ok <- root?(root),
         {:ok, marker} <- metadata(native, :root, root, "STORE-V2", 28),
         {:ok, current} <- metadata(native, :root, root, "CURRENT", 76),
         {:ok, pointer} <- Authority.decode_current(current),
         true <- pointer.epoch_id == epoch_id || {:error, :source_epoch_changed},
         {:ok, epoch_entries} <- Native.list(native, :epoch),
         :ok <- epoch?(epoch_entries),
         {:ok, manifest_bytes} <-
           metadata(native, :epoch, epoch_entries, "MANIFEST", @max_metadata),
         {:ok, manifest} <- Authority.verify_selection(marker, current, manifest_bytes),
         :ok <- index_topology(epoch_entries, manifest),
         {:ok, segment_entries} <- Native.list(native, :segments),
         {:ok, classified} <- Reader.classify_entries(segment_entries, :segments),
         true <- classified.unrelated == [] || {:error, :unexpected_epoch_segment_entry},
         frozen <-
           Enum.reject(classified.canonical, fn {segment_id, _} ->
             segment_id >= exclude_segment_id
           end),
         {:ok, result} <-
           replay_frozen_selected(
             native,
             candidate,
             frozen,
             manifest,
             exclude_segment_id,
             options
           ),
         :ok <- revalidate_root(native, root, marker, current),
         :ok <- Native.check(native) do
      {:ok,
       Map.merge(result, %{
         store_id: manifest.store_id,
         epoch_id: epoch_id,
         manifest: manifest,
         current: current
       })}
    end
  end

  defp replay_frozen_selected(native, candidate, canonical, manifest, exclude, options) do
    if Keyword.get(options, :reuse, false) and
         match?(%{auxiliary: _}, Map.get(manifest, :recovery_index)) and
         length(canonical) == length(manifest.base_segments) and
         exclude == manifest.tail_segment_id do
      replay_indexed(native, candidate, canonical, manifest, true)
    else
      replay_frozen(native, candidate, canonical, manifest, exclude)
    end
  end

  defp replay_frozen(native, candidate, canonical, manifest, exclude_segment_id) do
    base_count = length(manifest.base_segments)

    cond do
      length(canonical) >= base_count + 1 ->
        replay(native, :segments, candidate, canonical, manifest)

      canonical == [] and base_count == 0 and manifest.tail_first_sequence == 1 and
          exclude_segment_id == manifest.tail_segment_id ->
        {:ok,
         %{
           candidate: candidate,
           store: nil,
           highest: nil,
           next_sequence: 1,
           total_segment_bytes: 0,
           record_count: 0,
           segment_count: 0
         }}

      length(canonical) == base_count and exclude_segment_id == manifest.tail_segment_id ->
        with {:ok, summaries, state} <-
               scan_all(native, :segments, canonical, manifest, candidate),
             :ok <-
               verify_index(
                 native,
                 :segments,
                 manifest,
                 state.locations,
                 state.auxiliary_locations
               ),
             {:ok, topology} <- Reader.validate_topology(summaries),
             true <-
               state.next_sequence == manifest.tail_first_sequence ||
                 {:error, :tail_frontier} do
          {:ok,
           %{
             candidate: state.candidate,
             store: topology,
             highest: List.last(summaries),
             next_sequence: state.next_sequence,
             total_segment_bytes: Enum.sum(Enum.map(summaries, & &1.bytes)),
             record_count: Enum.sum(Enum.map(summaries, & &1.count)),
             segment_count: length(summaries)
           }}
        end

      true ->
        {:error, :source_segments_missing}
    end
  end

  @doc "Independently replays a private or just-renamed candidate before CURRENT publication."
  def recover_candidate(native, candidate, manifest) do
    with :ok <- Native.check(native),
         {:ok, epoch_entries} <- Native.list(native, :candidate),
         :ok <- epoch?(epoch_entries),
         {:ok, manifest_bytes} <-
           metadata(native, :candidate, epoch_entries, "MANIFEST", @max_metadata),
         {:ok, ^manifest} <- Authority.decode_manifest(manifest_bytes),
         :ok <- index_topology(epoch_entries, manifest),
         {:ok, segment_entries} <- Native.list(native, :candidate_segments),
         {:ok, classified} <- Reader.classify_entries(segment_entries, :segments),
         true <- classified.unrelated == [] || {:error, :unexpected_epoch_segment_entry},
         {:ok, result} <-
           replay(native, :candidate_segments, candidate, classified.canonical, manifest),
         :ok <- Native.check(native) do
      {:ok, Map.put(result, :manifest_bytes, manifest_bytes)}
    else
      {:ok, _} -> {:error, :candidate_manifest_mismatch}
      error -> error
    end
  end

  defp runtime_replay(native, candidate, canonical, manifest, options) do
    if Keyword.get(options, :indexed, false) and
         match?(%{auxiliary: _}, Map.get(manifest, :recovery_index)) do
      replay_indexed(native, candidate, canonical, manifest)
    else
      replay(native, :segments, candidate, canonical, manifest)
    end
  end

  defp replay_indexed(native, candidate, canonical, manifest, frozen \\ false) do
    base_count = length(manifest.base_segments)

    with true <-
           length(canonical) >= base_count + if(frozen, do: 0, else: 1) || {:error, :tail_missing},
         true <-
           Enum.map(canonical, &elem(&1, 0)) == Enum.to_list(1..length(canonical)) ||
             {:error, :segment_ids},
         {:ok, loaded, auxiliary} <-
           RecoveryIndex.load(
             native,
             manifest.recovery_index,
             candidate.limits,
             candidate.value_limits
           ),
         {:ok, bases} <- indexed_bases(native, canonical, manifest),
         state = %{
           candidate: loaded,
           next_sequence: map_size(loaded.jobs) + 1,
           last_snapshot_id: nil
         },
         {:ok, state} <-
           Enum.reduce_while(auxiliary, {:ok, state}, fn pointer, {:ok, acc} ->
             result =
               with {:ok, record} <- RecoveryIndex.read_record(native, pointer),
                    do: consume(record, true, acc)

             case result do
               {:cont, next} -> {:cont, {:ok, next}}
               error -> {:halt, error}
             end
           end),
         true <- state.next_sequence == manifest.tail_first_sequence || {:error, :tail_frontier},
         {:ok, state} <- seed_availability_frontier(state, manifest, base_count + 1, base_count),
         {:ok, summaries, state} <-
           indexed_tail(native, Enum.drop(canonical, base_count), bases, state, manifest),
         {:ok, topology} <- Reader.validate_topology(summaries) do
      {:ok,
       %{
         candidate: state.candidate,
         store: topology,
         highest: List.last(summaries),
         next_sequence: state.next_sequence,
         total_segment_bytes: Enum.sum(Enum.map(summaries, & &1.bytes)),
         record_count: Enum.sum(Enum.map(summaries, & &1.count)),
         segment_count: length(summaries),
         indexed: true
       }}
    end
  end

  defp indexed_bases(native, canonical, manifest) do
    Enum.reduce_while(Enum.zip(canonical, manifest.base_segments), {:ok, []}, fn {{id, entry},
                                                                                  base},
                                                                                 {:ok, acc} ->
      result =
        with_file(native, :segments, entry, fn ->
          with true <- entry.size == base.bytes || {:error, :base_size},
               {:ok, header} <- exact_read(native, 0, 44),
               {:ok, decoded} <-
                 Segment.decode_header(header, %{id: id, store_id: manifest.store_id}),
               true <- decoded.first_sequence == base.first_sequence || {:error, :base_inventory},
               {:ok, footer} <- exact_read(native, entry.size - 64, 64),
               {:ok, decoded_footer} <-
                 Segment.decode_footer(footer, %{id: id, store_id: manifest.store_id}),
               true <-
                 (decoded_footer.first_sequence == base.first_sequence and
                    decoded_footer.last_sequence == base.last_sequence) ||
                   {:error, :base_inventory} do
            {:ok,
             Map.merge(decoded, %{
               state: :sealed,
               bytes: base.bytes,
               count: decoded_footer.count,
               last_sequence: base.last_sequence,
               footer: decoded_footer,
               digest: base.digest,
               identity: entry
             })}
          end
        end)

      case result do
        {:ok, summary} -> {:cont, {:ok, [summary | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bases} -> {:ok, Enum.reverse(bases)}
      error -> error
    end
  end

  defp indexed_tail(native, tail, bases, state, manifest) do
    Enum.reduce_while(Enum.with_index(tail, 1), {:ok, bases, state}, fn {{id, entry}, ordinal},
                                                                        {:ok, summaries, acc} ->
      result =
        with_file(native, :segments, entry, fn ->
          buffered_reduce(
            native,
            entry.size,
            acc,
            fn record, _offset, current ->
              with {:ok, current} <-
                     hydrate(native, manifest.recovery_index, record, current, entry),
                   do: consume(record, false, current)
            end,
            id: id,
            store_id: manifest.store_id,
            highest: ordinal == length(tail)
          )
        end)

      case result do
        {:ok, summary, next} ->
          {:cont, {:ok, summaries ++ [Map.put(summary, :identity, entry)], next}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp hydrate(native, descriptor, record, state, entry) do
    id =
      case record do
        %{record_type: 8, payload_schema_version: 1, payload: <<id::binary-size(16), _::binary>>} ->
          id

        _ ->
          nil
      end

    case Map.get(state.candidate.jobs, id) do
      %{cold: true} ->
        with :ok <- Native.close_read(native),
             {:ok, job} <- RecoveryIndex.fetch(native, descriptor, id),
             {:ok, reopened} <- Native.open_read(native, :segments, entry.name),
             true <-
               Map.take(reopened, [:device, :inode, :size, :links, :type]) ==
                 Map.take(entry, [:device, :inode, :size, :links, :type]) ||
                 {:error, :file_identity_changed},
             {:ok, candidate} <-
               Reducer.insert_snapshot(
                 %{state.candidate | jobs: Map.delete(state.candidate.jobs, id)},
                 job
               ),
             do: {:ok, %{state | candidate: candidate}}

      _ ->
        {:ok, state}
    end
  end

  defp root?(entries) do
    names = Map.new(entries, &{&1.name, &1})

    cond do
      Map.has_key?(names, "segments") ->
        {:error, :unexpected_root_segments}

      Map.has_key?(names, "ADOPTION") ->
        {:error, :store_v1_metadata_unsupported}

      not match?(%{type: :directory}, names["epochs"]) ->
        {:error, :epochs_missing}

      not Enum.all?(
        ["STORE-V2", "CURRENT"],
        &match?(%{type: :regular, links: 1}, names[&1])
      ) ->
        {:error, :authority_metadata_missing}

      Enum.any?(entries, &(&1.type in [:symlink, :other])) ->
        {:error, :unsupported_root_entry}

      Enum.any?(entries, &(&1.type == :directory and &1.name != "epochs")) ->
        {:error, :unexpected_root_directory}

      true ->
        :ok
    end
  end

  defp epoch?(entries) do
    case Map.new(entries, &{&1.name, &1}) do
      %{
        "MANIFEST" => %{type: :regular, links: 1},
        "segments" => %{type: :directory}
      } = named
      when map_size(named) in [2, 3] ->
        if map_size(named) == 3 and not match?(%{type: :regular, links: 1}, named["RECOVERY"]),
          do: {:error, :unexpected_epoch_topology},
          else: :ok

      _ ->
        {:error, :unexpected_epoch_topology}
    end
  end

  defp index_topology(entries, manifest) do
    file = Enum.find(entries, &(&1.name == "RECOVERY"))

    case {file, Map.get(manifest, :recovery_index)} do
      {nil, nil} -> :ok
      {%{type: :regular, links: 1, size: size}, %{bytes: size}} -> :ok
      _ -> {:error, :recovery_index_topology}
    end
  end

  defp maybe_select(native, id, options) do
    if Keyword.get(options, :selected, false), do: :ok, else: Native.v2_select(native, id)
  end

  defp metadata(native, scope, entries, name, max_size) do
    case Enum.find(entries, &(&1.name == name)) do
      %{type: :regular, links: 1, size: size} = entry when size in 1..max_size//1 ->
        with_file(native, scope, entry, fn -> exact_read(native, 0, size) end)

      _ ->
        {:error, {:metadata_missing_or_invalid, name}}
    end
  end

  defp revalidate_root(native, root, marker, current) do
    with {:ok, actual} <- Native.list(native, :root),
         true <- actual == root || {:error, :root_changed},
         {:ok, ^marker} <- metadata(native, :root, actual, "STORE-V2", 28),
         {:ok, ^current} <- metadata(native, :root, actual, "CURRENT", 76) do
      :ok
    else
      {:ok, _} -> {:error, :authority_changed}
      error -> error
    end
  end

  defp replay(native, scope, candidate, canonical, manifest) do
    base_count = length(manifest.base_segments)
    tail_id = manifest.tail_segment_id

    with true <-
           length(canonical) >= base_count + 1 || {:error, :tail_missing},
         true <- tail_id == base_count + 1 || {:error, :tail_id},
         true <-
           Enum.map(canonical, &elem(&1, 0)) == Enum.to_list(1..length(canonical)) ||
             {:error, :segment_ids},
         {:ok, summaries, state} <- scan_all(native, scope, canonical, manifest, candidate),
         :ok <- verify_index(native, scope, manifest, state.locations, state.auxiliary_locations),
         {:ok, topology} <- Reader.validate_topology(summaries),
         true <-
           Enum.at(summaries, base_count).first_sequence == manifest.tail_first_sequence ||
             {:error, :tail_frontier} do
      {:ok,
       %{
         candidate: state.candidate,
         store: topology,
         highest: List.last(summaries),
         next_sequence: state.next_sequence,
         total_segment_bytes: Enum.sum(Enum.map(summaries, & &1.bytes)),
         record_count: Enum.sum(Enum.map(summaries, & &1.count)),
         segment_count: length(summaries)
       }}
    end
  end

  defp physical_replay(native, canonical, manifest) do
    total = length(canonical)
    base_count = length(manifest.base_segments)

    with true <- length(canonical) >= base_count + 1 || {:error, :tail_missing},
         true <- manifest.tail_segment_id == base_count + 1 || {:error, :tail_id},
         true <-
           Enum.map(canonical, &elem(&1, 0)) == Enum.to_list(1..total) ||
             {:error, :segment_ids},
         {:ok, summaries} <- physical_scan_all(native, canonical, manifest),
         :ok <- verify_index(native, :segments, manifest, nil),
         {:ok, topology} <- Reader.validate_topology(summaries),
         true <-
           Enum.at(summaries, base_count).first_sequence == manifest.tail_first_sequence ||
             {:error, :tail_frontier} do
      {:ok,
       %{
         store: topology,
         highest: List.last(summaries),
         next_sequence: topology.next_sequence,
         total_segment_bytes: Enum.sum(Enum.map(summaries, & &1.bytes)),
         record_count: Enum.sum(Enum.map(summaries, & &1.count)),
         segment_count: length(summaries)
       }}
    end
  end

  defp physical_scan_all(native, canonical, manifest) do
    total = length(canonical)
    base_count = length(manifest.base_segments)

    canonical
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{id, entry}, ordinal}, {:ok, summaries} ->
      result =
        with_file(native, :segments, entry, fn ->
          with :ok <- base_size(entry, manifest, ordinal),
               {:ok, summary} <-
                 BufferedRead.with_reader(&Native.read(native, &1, &2), entry.size, fn read ->
                   Segment.scan(read, entry.size,
                     id: id,
                     store_id: manifest.store_id,
                     highest: ordinal == total,
                     sha256: ordinal <= base_count
                   )
                 end),
               :ok <- base_digest(summary, manifest, ordinal),
               :ok <- segment_profile(summary, manifest, ordinal, ordinal <= base_count) do
            {:ok, Map.put(summary, :identity, entry)}
          end
        end)

      case result do
        {:ok, summary} -> {:cont, {:ok, [summary | summaries]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp scan_all(native, scope, canonical, manifest, candidate) do
    total = length(canonical)
    base_count = length(manifest.base_segments)

    canonical
    |> Enum.with_index(1)
    |> Enum.reduce_while(
      {:ok, [],
       %{
         candidate: candidate,
         next_sequence: 1,
         last_snapshot_id: nil,
         locations: if(Map.has_key?(manifest, :recovery_index), do: %{}, else: nil),
         index_summaries: match?(%{auxiliary: _}, Map.get(manifest, :recovery_index)),
         auxiliary_locations:
           if(match?(%{auxiliary: _}, Map.get(manifest, :recovery_index)), do: %{}, else: nil)
       }},
      fn
        {{id, entry}, ordinal}, {:ok, summaries, state} ->
          base? = ordinal <= base_count

          result =
            with {:ok, state} <- seed_availability_frontier(state, manifest, ordinal, base_count),
                 result <-
                   with_file(native, scope, entry, fn ->
                     with :ok <- base_size(entry, manifest, ordinal),
                          {:ok, summary, next} <-
                            buffered_reduce(
                              native,
                              entry.size,
                              state,
                              fn record, offset, acc ->
                                consume_indexed(record, base?, acc, id, offset)
                              end,
                              id: id,
                              store_id: manifest.store_id,
                              highest: ordinal == total,
                              sha256: true
                            ),
                          :ok <- base_digest(summary, manifest, ordinal),
                          :ok <- segment_profile(summary, manifest, ordinal, base?) do
                       {:ok, summary, next}
                     end
                   end),
                 do: result

          case result do
            {:ok, summary, next} ->
              {:cont, {:ok, [Map.put(summary, :identity, entry) | summaries], next}}

            error ->
              {:halt, error}
          end
      end
    )
    |> case do
      {:ok, summaries, state} -> {:ok, Enum.reverse(summaries), state}
      error -> error
    end
  end

  defp verify_index(native, scope, manifest, expected, auxiliary \\ nil)

  defp verify_index(native, scope, %{recovery_index: descriptor}, expected, auxiliary) do
    index_scope = if scope == :candidate_segments, do: :candidate, else: :epoch

    with {:ok, entries} <- Native.list(native, index_scope),
         do: RecoveryIndex.verify(native, index_scope, entries, descriptor, expected, auxiliary)
  end

  defp verify_index(_native, _scope, _manifest, _expected, _auxiliary), do: :ok

  defp consume_indexed(record, base?, state, segment, offset) do
    with {:cont, next} <- consume(record, base?, state) do
      if base? and record.record_type == 7 and record.payload_schema_version == 1 and
           is_map(next.locations) do
        {:cont,
         %{
           next
           | locations:
               Map.put(
                 next.locations,
                 next.last_snapshot_id,
                 if(next.index_summaries,
                   do:
                     RecoveryIndex.location(
                       segment,
                       offset,
                       record,
                       next.candidate.jobs[next.last_snapshot_id]
                     ),
                   else: RecoveryIndex.location(segment, offset, record)
                 )
               )
         }}
      else
        if base? and is_map(next.auxiliary_locations) do
          {:cont,
           put_in(
             next.auxiliary_locations[<<record.sequence::64>>],
             RecoveryIndex.location(segment, offset, record)
           )}
        else
          {:cont, next}
        end
      end
    end
  end

  defp consume(record, base?, state) do
    with true <- record.sequence == state.next_sequence || {:error, :physical_sequence},
         {:ok, candidate, id} <- consume_kind(record, base?, state) do
      {:cont,
       %{
         state
         | candidate: candidate,
           next_sequence: state.next_sequence + 1,
           last_snapshot_id: id
       }}
    end
  end

  defp seed_availability_frontier(state, manifest, ordinal, base_count)
       when ordinal == base_count + 1 do
    case Map.get(manifest, :availability_frontier) do
      nil ->
        {:ok, state}

      frontier when frontier + 1 >= state.candidate.next_availability_order ->
        {:ok, put_in(state.candidate.next_availability_order, frontier + 1)}

      _ ->
        {:error, :availability_frontier}
    end
  end

  defp seed_availability_frontier(state, _manifest, _ordinal, _base_count), do: {:ok, state}

  defp consume_kind(
         %{record_type: 7, payload_schema_version: 1, payload: payload},
         true,
         state
       ) do
    with {:ok, job} <- Codec.decode_snapshot(payload, state.candidate.value_limits),
         true <-
           (is_nil(state.last_snapshot_id) or job.id > state.last_snapshot_id) ||
             {:error, :snapshot_order},
         {:ok, next} <- Reducer.insert_snapshot(state.candidate, job) do
      {:ok, next, job.id}
    end
  end

  defp consume_kind(
         %{record_type: 8, payload_schema_version: 1, payload: payload},
         false,
         state
       ) do
    with {:ok, mutation} <- Codec.decode_mutation(payload, state.candidate.value_limits),
         {:ok, next} <- Reducer.apply(state.candidate, mutation) do
      {:ok, next, state.last_snapshot_id}
    end
  end

  defp consume_kind(
         %{record_type: type, payload_schema_version: 2, payload: payload} = record,
         _base?,
         state
       )
       when Tay.Event.V2.is_auxiliary(type) do
    with {:ok, event, _} <- Event.decode_payload(type, 2, payload, state.candidate.value_limits),
         {:ok, next} <- Reducer.apply_event(state.candidate, event, %{sequence: record.sequence}) do
      {:ok, next, state.last_snapshot_id}
    end
  end

  defp consume_kind(_, _, _), do: {:error, :record_profile}

  defp segment_profile(summary, manifest, ordinal, true) do
    entry = Enum.at(manifest.base_segments, ordinal - 1)

    if summary.state == :sealed and summary.id == entry.id and
         summary.first_sequence == entry.first_sequence and
         summary.last_sequence == entry.last_sequence and summary.bytes == entry.bytes,
       do: :ok,
       else: {:error, :base_inventory}
  end

  defp segment_profile(summary, manifest, ordinal, false) do
    if ordinal == length(manifest.base_segments) + 1 and
         summary.first_sequence != manifest.tail_first_sequence,
       do: {:error, :tail_frontier},
       else: :ok
  end

  defp base_size(entry, manifest, ordinal) do
    case Enum.at(manifest.base_segments, ordinal - 1) do
      nil -> :ok
      expected -> if entry.size == expected.bytes, do: :ok, else: {:error, :base_size}
    end
  end

  defp base_digest(summary, manifest, ordinal) do
    case Enum.at(manifest.base_segments, ordinal - 1) do
      nil -> :ok
      expected -> if summary.digest == expected.digest, do: :ok, else: {:error, :base_digest}
    end
  end

  defp with_file(native, scope, entry, fun) do
    with {:ok, opened} <- Native.open_read(native, scope, entry.name) do
      result =
        if Map.take(opened, [:device, :inode, :size, :links, :type]) ==
             Map.take(entry, [:device, :inode, :size, :links, :type]),
           do: fun.(),
           else: {:error, :file_identity_changed}

      case Native.close_read(native) do
        :ok -> result
        error -> error
      end
    end
  end

  defp exact_read(native, offset, length) do
    case Native.read(native, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _} -> {:error, :short_read}
      error -> error
    end
  end

  defp buffered_reduce(native, size, accumulator, visitor, options) do
    BufferedRead.with_reader(&Native.read(native, &1, &2), size, fn read ->
      Segment.reduce_while(
        read,
        size,
        accumulator,
        visitor,
        options
      )
    end)
  end
end
