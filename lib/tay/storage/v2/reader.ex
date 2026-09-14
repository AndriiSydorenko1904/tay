defmodule Tay.Storage.V2.Reader do
  @moduledoc """
  Store-v2 recovery through the lock-owning native session. No path is opened
  through File; every read is pinned, positional, bounded and revalidated.
  """

  alias Tay.Storage.{Native, Reader, Segment}
  alias Tay.Storage.V2.{Authority, Codec, Reducer}

  @max_metadata 16_777_216
  @digest_chunk 1_048_576

  @doc "Rolls back an interrupted first adoption under the retained ownership lock."
  def reconcile_adoption(native) do
    with {:ok, root} <- Native.list(native, :root) do
      names = Map.new(root, &{&1.name, &1})

      cond do
        Map.has_key?(names, "CURRENT") ->
          :ok

        Map.has_key?(names, "ADOPTION") ->
          with {:ok, bytes} <- metadata(native, :root, root, "ADOPTION", 28),
               {:ok, nonce} <- Authority.decode_adoption(bytes),
               :ok <- Native.v2_restore_v1(native, nonce),
               :ok <- Native.v2_clear_adoption(native),
               {:ok, after_restore} <- Native.list(native, :root),
               true <-
                 Enum.any?(after_restore, &(&1.name == "segments" and &1.type == :directory)) ||
                   {:error, :v1_restore_missing},
               do: :ok

        Map.has_key?(names, "STORE-V2") ->
          {:error, :incomplete_adoption_without_intent}

        true ->
          :ok
      end
    end
  end

  def recover(native, candidate, options \\ []) do
    with :ok <- Native.check(native),
         {:ok, root} <- Native.list(native, :root),
         :ok <- root?(root),
         {:ok, store_bytes} <- metadata(native, :root, root, "STORE", 28),
         {:ok, store_id} <- Segment.decode_store(store_bytes),
         {:ok, marker} <- metadata(native, :root, root, "STORE-V2", 28),
         {:ok, current} <- metadata(native, :root, root, "CURRENT", 76),
         {:ok, pointer} <- Authority.decode_current(current),
         true <- pointer.store_id == store_id || {:error, :store_id_mismatch},
         :ok <- maybe_select(native, pointer.epoch_id, options),
         {:ok, epoch_entries} <- Native.list(native, :epoch),
         {:ok, manifest_bytes} <-
           metadata(native, :epoch, epoch_entries, "MANIFEST", @max_metadata),
         {:ok, manifest} <- Authority.verify_selection(marker, current, manifest_bytes),
         true <- manifest.store_id == store_id || {:error, :store_id_mismatch},
         {:ok, segment_entries} <- Native.list(native, :segments),
         {:ok, classified} <- Reader.classify_entries(segment_entries, :segments),
         {:ok, result} <- replay(native, :segments, candidate, classified.canonical, manifest),
         :ok <- revalidate_root(native, root, store_bytes, marker, current),
         :ok <- Native.check(native) do
      {:ok,
       Map.merge(result, %{
         store_id: store_id,
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

  @doc "Independently replays a private or just-renamed candidate before CURRENT publication."
  def recover_candidate(native, candidate, manifest) do
    with :ok <- Native.check(native),
         {:ok, epoch_entries} <- Native.list(native, :candidate),
         {:ok, manifest_bytes} <-
           metadata(native, :candidate, epoch_entries, "MANIFEST", @max_metadata),
         {:ok, ^manifest} <- Authority.decode_manifest(manifest_bytes),
         {:ok, segment_entries} <- Native.list(native, :candidate_segments),
         {:ok, classified} <- Reader.classify_entries(segment_entries, :segments),
         {:ok, result} <-
           replay(native, :candidate_segments, candidate, classified.canonical, manifest),
         :ok <- Native.check(native) do
      {:ok, Map.put(result, :manifest_bytes, manifest_bytes)}
    else
      {:ok, _} -> {:error, :candidate_manifest_mismatch}
      error -> error
    end
  end

  defp root?(entries) do
    names = Map.new(entries, &{&1.name, &1})

    cond do
      Map.has_key?(names, "segments") ->
        {:error, :v2_root_has_v1_segments}

      not match?(%{type: :directory}, names["epochs"]) ->
        {:error, :epochs_missing}

      not Enum.all?(
        ["STORE", "STORE-V2", "CURRENT"],
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

  defp revalidate_root(native, root, store_bytes, marker, current) do
    with {:ok, actual} <- Native.list(native, :root),
         true <- actual == root || {:error, :root_changed},
         {:ok, ^store_bytes} <- metadata(native, :root, actual, "STORE", 28),
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

    with true <- length(canonical) >= base_count + 1 || {:error, :tail_missing},
         true <- tail_id == base_count + 1 || {:error, :tail_id},
         true <-
           Enum.map(canonical, &elem(&1, 0)) == Enum.to_list(1..length(canonical)) ||
             {:error, :segment_ids},
         {:ok, summaries, state} <- scan_all(native, scope, canonical, manifest, candidate),
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

  defp scan_all(native, scope, canonical, manifest, candidate) do
    total = length(canonical)
    base_count = length(manifest.base_segments)

    canonical
    |> Enum.with_index(1)
    |> Enum.reduce_while(
      {:ok, [], %{candidate: candidate, next_sequence: 1, last_snapshot_id: nil}},
      fn
        {{id, entry}, ordinal}, {:ok, summaries, state} ->
          base? = ordinal <= base_count

          result =
            with_file(native, scope, entry, fn ->
              with :ok <- maybe_digest(native, entry, manifest, ordinal),
                   {:ok, summary, next} <-
                     Segment.reduce_while(
                       &Native.read(native, &1, &2),
                       entry.size,
                       state,
                       fn record, _offset, acc -> consume(record, base?, acc) end,
                       id: id,
                       store_id: manifest.store_id,
                       highest: ordinal == total
                     ),
                   :ok <- segment_profile(summary, manifest, ordinal, base?) do
                {:ok, summary, next}
              end
            end)

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

  defp consume(record, base?, state) do
    with true <- record.sequence == state.next_sequence || {:error, :physical_sequence},
         true <- record.payload_schema_version == 1 || {:error, :payload_schema},
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

  defp consume_kind(%{record_type: 7, payload: payload}, true, state) do
    with {:ok, job} <- Codec.decode_snapshot(payload, state.candidate.value_limits),
         true <-
           (is_nil(state.last_snapshot_id) or job.id > state.last_snapshot_id) ||
             {:error, :snapshot_order},
         {:ok, next} <- Reducer.insert_snapshot(state.candidate, job) do
      {:ok, next, job.id}
    end
  end

  defp consume_kind(%{record_type: 8, payload: payload}, false, state) do
    with {:ok, mutation} <- Codec.decode_mutation(payload, state.candidate.value_limits),
         {:ok, next} <- Reducer.apply(state.candidate, mutation) do
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

  defp maybe_digest(_native, _entry, _manifest, ordinal) when ordinal < 1, do: :ok

  defp maybe_digest(native, entry, manifest, ordinal) do
    case Enum.at(manifest.base_segments, ordinal - 1) do
      nil ->
        :ok

      expected ->
        with true <- entry.size == expected.bytes || {:error, :base_size},
             {:ok, digest} <- digest(native, 0, entry.size, :crypto.hash_init(:sha256)),
             true <- digest == expected.digest || {:error, :base_digest} do
          :ok
        end
    end
  end

  defp digest(_native, _offset, 0, context), do: {:ok, :crypto.hash_final(context)}

  defp digest(native, offset, remaining, context) do
    length = min(remaining, @digest_chunk)

    with {:ok, bytes} <- exact_read(native, offset, length) do
      digest(native, offset + length, remaining - length, :crypto.hash_update(context, bytes))
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
end
