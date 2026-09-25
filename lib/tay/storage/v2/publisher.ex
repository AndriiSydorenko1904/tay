defmodule Tay.Storage.V2.Publisher do
  @moduledoc """
  Store-v2 candidate construction and publication. Online callers build the
  candidate against a frozen frontier while the Writer journals later mutations,
  then catch up under a fenced epoch switch. The source remains pinned and never
  loses bytes to make candidate space. A return after CURRENT publication is
  verified by an independent Store-v2 replay.
  """

  alias Tay.Event.V1
  alias Tay.Storage.{CRC32C, Native, Reader, Record, Segment}
  alias Tay.Storage.V2.{Authority, Codec, Reducer, Snapshot}
  alias Tay.Storage.V2.Reader, as: V2Reader

  @max 18_446_744_073_709_551_615
  @digest_chunk 1_048_576
  @minimum_headroom 67_108_864

  def publish(native, source) do
    started = System.monotonic_time(:millisecond)
    limits = Map.fetch!(source, :candidate_limits)
    value_limits = Map.fetch!(source, :value_limits)

    source =
      source
      |> Map.put_new(:terminal_retention, :infinity)
      |> Map.put_new(:max_terminal_jobs, :infinity)
      |> Map.put_new_lazy(:captured_at, fn -> System.system_time(:millisecond) end)

    with true <- V1.id?(source.store_id) || {:error, :store_id},
         true <-
           (is_nil(source.epoch_id) or V1.id?(source.epoch_id)) ||
             {:error, :source_epoch},
         {:ok, normalized, ids, retention_stats} <-
           prepare_snapshot(
             source.jobs,
             source.terminal_retention,
             source.captured_at,
             source.max_terminal_jobs,
             Map.has_key?(source, :online_catch_up)
           ),
         {:ok, inventory} <- source_inventory(native, source.store_id, source),
         true <- inventory.frontier == source.frontier || {:error, :source_frontier_changed},
         {:ok, estimate} <-
           estimate(normalized, ids, source.rotation_target_bytes, native.deadline),
         {:ok, admitted_candidate_bytes} <-
           admit_space(native, estimate, length(inventory.sealed), source),
         :ok <- deadline_ok(native.deadline),
         :ok <- boundary(source, :before_candidate),
         epoch_id <- new_id(),
         nonce <- new_id(),
         :ok <- Native.v2_begin(native, nonce),
         {:ok, base, base_bytes, peak_memory} <-
           write_base(
             native,
             normalized,
             ids,
             source.store_id,
             source.rotation_target_bytes,
             source
           ),
         tail_id <- length(base) + 1,
         tail_first <- length(ids) + 1,
         manifest <- manifest(source, inventory, epoch_id, base, tail_id, tail_first),
         {:ok, manifest_bytes} <- Authority.encode_manifest(manifest),
         :ok <- write_manifest(native, manifest_bytes),
         {:ok, tail, tail_bytes} <- write_tail(native, source.store_id, tail_id, tail_first),
         :ok <- Native.sync_dir(native, :candidate_segments),
         {:ok, candidate} <-
           V2Reader.recover_candidate(native, Reducer.candidate(limits, value_limits), manifest),
         true <-
           Snapshot.equivalent?(normalized, candidate.candidate.jobs) ||
             {:error, :candidate_mismatch},
         {:ok, caught_up, _tail, delta_bytes, switch_started} <-
           catch_up(native, source, candidate, tail, started),
         :ok <- Native.sync(native),
         :ok <- Native.close_write(native),
         :ok <- Native.v2_publish_epoch(native, epoch_id),
         :ok <- boundary(source, :epoch_published),
         {:ok, renamed} <-
           V2Reader.recover_candidate(native, Reducer.candidate(limits, value_limits), manifest),
         true <-
           Snapshot.equivalent?(caught_up, renamed.candidate.jobs) ||
             {:error, :renamed_candidate_mismatch},
         :ok <- before_current(native, source, epoch_id),
         {:ok, current_bytes} <-
           Authority.encode_current(%{
             store_id: source.store_id,
             epoch_id: epoch_id,
             manifest_digest: Authority.manifest_digest(manifest_bytes)
           }),
         {:ok, stage, identity, previous} <- stage_current(native, source, current_bytes),
         :ok <- boundary(source, :before_current),
         :ok <- deadline_ok(native.deadline),
         :ok <- Tay.Storage.V2.CompactionControl.begin_current() do
      publication =
        %{
          epoch_id: epoch_id,
          current: current_bytes,
          source_bytes: inventory.total_bytes,
          admitted_candidate_bytes: admitted_candidate_bytes,
          candidate_bytes:
            base_bytes + tail_bytes + delta_bytes + byte_size(manifest_bytes) +
              byte_size(current_bytes) +
              if(is_nil(source.epoch_id), do: 56, else: 0),
          peak_writer_process_bytes: peak_memory,
          started: started,
          switch_started: switch_started,
          previous_epoch_id: source.epoch_id
        }
        |> Map.merge(retention_stats)
        |> Map.merge(%{
          terminal_retention: source.terminal_retention,
          max_terminal_jobs: source.max_terminal_jobs,
          captured_at: source.captured_at
        })

      case Native.v2_publish_current(native, stage, identity, previous) do
        :ok ->
          :ok = boundary(source, :current_published)

          case verify_published(native, source, caught_up, limits, value_limits, publication) do
            {:ok, _} = result ->
              result

            error ->
              {:error, {:unknown_publication_outcome, Map.put(publication, :reason, error)}}
          end

        error ->
          {:error, {:unknown_publication_outcome, Map.put(publication, :reason, error)}}
      end
    end
  end

  defp new_id do
    case :crypto.strong_rand_bytes(16) do
      <<0::128>> -> new_id()
      bytes -> bytes
    end
  end

  defp source_inventory(native, store_id, source) do
    with {:ok, entries} <- Native.list(native, :segments),
         {:ok, classified} <- Reader.classify_entries(entries, :segments),
         true <- classified.canonical != [] || {:error, :source_segments_missing},
         canonical <- frozen_canonical(classified.canonical, source) do
      total_bytes = Enum.sum(Enum.map(classified.canonical, fn {_, entry} -> entry.size end))
      segment_count = length(classified.canonical)

      if canonical == [] and is_binary(Map.get(source, :epoch_id)) do
        {:ok,
         %{
           frontier: source.frontier,
           sealed: [],
           total_bytes: total_bytes,
           segment_count: segment_count
         }}
      else
        with true <- canonical != [] || {:error, :source_segments_missing},
             {:ok, summaries, sealed} <- scan_source(native, canonical, store_id),
             {:ok, topology} <- Reader.validate_topology(summaries) do
          {:ok,
           %{
             frontier: topology.next_sequence - 1,
             sealed: sealed,
             total_bytes: total_bytes,
             segment_count: segment_count
           }}
        end
      end
    end
  end

  defp frozen_canonical(canonical, source) do
    case Map.get(source, :exclude_segment_id) do
      nil -> canonical
      id -> Enum.reject(canonical, fn {segment_id, _} -> segment_id >= id end)
    end
  end

  defp scan_source(native, canonical, store_id) do
    total = length(canonical)

    canonical
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], []}, fn {{id, entry}, ordinal}, {:ok, summaries, sealed} ->
      result =
        with_file(native, entry, fn ->
          with {:ok, summary} <-
                 Segment.scan(&Native.read(native, &1, &2), entry.size,
                   id: id,
                   store_id: store_id,
                   highest: ordinal == total
                 ),
               :ok <- source_state(summary, ordinal == total),
               {:ok, digest} <- maybe_source_digest(native, summary, entry.size) do
            {:ok, summary, digest}
          end
        end)

      case result do
        {:ok, summary, nil} ->
          {:cont, {:ok, [summary | summaries], sealed}}

        {:ok, summary, digest} ->
          {:cont, {:ok, [summary | summaries], [%{id: id, digest: digest} | sealed]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries, sealed} -> {:ok, Enum.reverse(summaries), Enum.reverse(sealed)}
      error -> error
    end
  end

  defp source_state(%{state: :sealed}, _), do: :ok
  defp source_state(%{state: :active, count: 0}, true), do: :ok
  defp source_state(_, _), do: {:error, :unsealed_source}

  defp maybe_source_digest(_native, %{state: :active}, _), do: {:ok, nil}

  defp maybe_source_digest(native, _, size),
    do: digest(native, 0, size, :crypto.hash_init(:sha256))

  defp with_file(native, entry, fun) do
    with {:ok, opened} <- Native.open_read(native, :segments, entry.name) do
      result =
        if Map.take(opened, [:device, :inode, :size, :links, :type]) ==
             Map.take(entry, [:device, :inode, :size, :links, :type]),
           do: fun.(),
           else: {:error, :source_identity_changed}

      case Native.close_read(native) do
        :ok -> result
        error -> error
      end
    end
  end

  defp digest(_native, _offset, 0, context), do: {:ok, :crypto.hash_final(context)}

  defp digest(native, offset, remaining, context) do
    length = min(remaining, @digest_chunk)

    case Native.read(native, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length ->
        digest(native, offset + length, remaining - length, :crypto.hash_update(context, bytes))

      {:ok, _} ->
        {:error, :short_source_read}

      error ->
        error
    end
  end

  defp estimate(jobs, ids, target, deadline) do
    Enum.reduce_while(ids, {:ok, %{current: 44, count: 0, total: 0, segments: 0}}, fn id,
                                                                                      {:ok, acc} ->
      case with :ok <- deadline_ok(deadline), do: Codec.encode_snapshot(jobs[id]) do
        {:ok, payload} ->
          size = byte_size(payload) + 28

          cond do
            44 + size + 64 > Segment.max_bytes() ->
              {:halt, {:error, :snapshot_exceeds_segment}}

            acc.count > 0 and acc.current + size + 64 > target ->
              {:cont,
               {:ok,
                %{
                  acc
                  | total: acc.total + acc.current + 64,
                    segments: acc.segments + 1,
                    current: 44 + size,
                    count: 1
                }}}

            true ->
              {:cont, {:ok, %{acc | current: acc.current + size, count: acc.count + 1}}}
          end

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, %{count: 0} = acc} ->
        {:ok, %{bytes: acc.total + 44, base_segments: acc.segments}}

      {:ok, acc} ->
        {:ok, %{bytes: acc.total + acc.current + 64 + 44, base_segments: acc.segments + 1}}

      error ->
        error
    end
  end

  defp admit_space(native, estimate, source_segments, source) do
    with {:ok, free} <- Native.v2_space(native) do
      metadata_allowance = (estimate.base_segments + source_segments) * 256 + 1_048_576
      required = estimate.bytes + metadata_allowance + @minimum_headroom
      limit = Map.get(source, :max_candidate_bytes, @max)

      cond do
        not is_integer(limit) or limit <= 0 -> {:error, :candidate_limit}
        estimate.bytes + metadata_allowance > limit -> {:error, :candidate_limit}
        free < required -> {:error, :insufficient_headroom}
        true -> {:ok, estimate.bytes + metadata_allowance}
      end
    end
  end

  defp write_base(native, jobs, ids, store_id, target, source) do
    Enum.with_index(ids, 1)
    |> Enum.reduce_while({:ok, nil, [], 0, process_memory()}, fn {id, sequence},
                                                                 {:ok, current, sealed, bytes,
                                                                  peak} ->
      with {:ok, payload} <- Codec.encode_snapshot(jobs[id]),
           :ok <- deadline_ok(native.deadline),
           {:ok, record} <-
             Record.encode(%Record{
               record_type: 7,
               payload_schema_version: 1,
               sequence: sequence,
               payload: payload
             }),
           {:ok, current, sealed, bytes} <-
             room(native, current, sealed, bytes, byte_size(record), sequence, store_id, target),
           {:ok, next} <- append_record(native, current, record),
           :ok <- boundary(source, :base_write) do
        {:cont, {:ok, next, sealed, bytes, max(peak, process_memory())}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nil, sealed, bytes, peak} ->
        {:ok, Enum.reverse(sealed), bytes, peak}

      {:ok, current, sealed, bytes, peak} ->
        with {:ok, entry} <- seal(native, current) do
          {:ok, Enum.reverse([entry | sealed]), bytes + entry.bytes, max(peak, process_memory())}
        end

      error ->
        error
    end
  end

  defp room(native, nil, sealed, bytes, _size, sequence, store_id, _target) do
    with {:ok, fresh} <- begin_segment(native, 1, sequence, store_id),
         do: {:ok, fresh, sealed, bytes}
  end

  defp room(native, current, sealed, bytes, size, sequence, store_id, target) do
    if current.size + size + 64 <= target do
      {:ok, current, sealed, bytes}
    else
      with {:ok, entry} <- seal(native, current),
           {:ok, fresh} <- begin_segment(native, current.id + 1, sequence, store_id) do
        {:ok, fresh, [entry | sealed], bytes + entry.bytes}
      end
    end
  end

  defp begin_segment(native, id, first, store_id) do
    with {:ok, name} <- Segment.filename(id),
         {:ok, header} <-
           Segment.encode_header(%{id: id, first_sequence: first, store_id: store_id}),
         {:ok, _} <- Native.create_stage(native, :candidate_segments, name),
         {:ok, _} <- Native.write(native, 0, header) do
      {:ok,
       %{
         id: id,
         first_sequence: first,
         count: 0,
         size: 44,
         crc: CRC32C.update(CRC32C.initial(), header),
         digest: :crypto.hash_update(:crypto.hash_init(:sha256), header),
         store_id: store_id
       }}
    end
  end

  defp append_record(native, current, record) do
    with {:ok, _} <- Native.write(native, current.size, record) do
      {:ok,
       %{
         current
         | count: current.count + 1,
           size: current.size + byte_size(record),
           crc: CRC32C.update(current.crc, record),
           digest: :crypto.hash_update(current.digest, record)
       }}
    end
  end

  defp seal(native, current) do
    last = current.first_sequence + current.count - 1

    footer = %{
      id: current.id,
      first_sequence: current.first_sequence,
      last_sequence: last,
      count: current.count,
      store_id: current.store_id,
      segment_crc: CRC32C.finalize(current.crc)
    }

    with {:ok, bytes} <- Segment.encode_footer(footer),
         {:ok, _} <- Native.write(native, current.size, bytes),
         :ok <- Native.sync(native),
         :ok <- Native.close_write(native) do
      {:ok,
       %{
         id: current.id,
         first_sequence: current.first_sequence,
         last_sequence: last,
         bytes: current.size + byte_size(bytes),
         digest: current.digest |> :crypto.hash_update(bytes) |> :crypto.hash_final()
       }}
    end
  end

  defp write_tail(native, store_id, id, first) do
    with {:ok, name} <- Segment.filename(id),
         {:ok, header} <-
           Segment.encode_header(%{id: id, first_sequence: first, store_id: store_id}),
         {:ok, _} <- Native.create_stage(native, :candidate_segments, name),
         {:ok, %{identity: identity}} <- Native.write(native, 0, header),
         :ok <- Native.sync(native) do
      {:ok,
       %{
         id: id,
         first_sequence: first,
         last_sequence: nil,
         count: 0,
         bytes: byte_size(header),
         store_id: store_id,
         state: :active,
         identity: identity,
         crc_state: CRC32C.update(CRC32C.initial(), header)
       }, byte_size(header)}
    end
  end

  defp prepare_snapshot(jobs, retention, captured_at, max_terminal_jobs, true),
    do: Snapshot.prepare_online(jobs, retention, captured_at, max_terminal_jobs)

  defp prepare_snapshot(jobs, retention, captured_at, max_terminal_jobs, false),
    do: Snapshot.prepare(jobs, retention, captured_at, max_terminal_jobs)

  defp catch_up(_native, source, candidate, tail, started)
       when not is_map_key(source, :online_catch_up),
       do: {:ok, candidate.candidate.jobs, tail, 0, started}

  defp catch_up(native, source, candidate, tail, _started) do
    switch_started = System.monotonic_time(:millisecond)

    case source.online_catch_up.() do
      {:ok, records} when is_list(records) ->
        Enum.reduce_while(records, {:ok, candidate.candidate, tail, 0}, fn
          {8, 1, payload}, {:ok, logical, current, bytes} ->
            with {:ok, mutation} <- Codec.decode_mutation(payload, source.value_limits),
                 {:ok, next_logical} <- Reducer.apply(logical, mutation),
                 {:ok, frame} <-
                   Record.encode(%Record{
                     record_type: 8,
                     payload_schema_version: 1,
                     sequence: current.first_sequence + current.count,
                     payload: payload
                   }),
                 true <-
                   current.bytes + byte_size(frame) + 64 <= Segment.max_bytes() ||
                     {:error, :online_delta_too_large},
                 {:ok, %{identity: identity}} <- Native.write(native, current.bytes, frame) do
              next = %{
                current
                | count: current.count + 1,
                  last_sequence: current.first_sequence + current.count,
                  bytes: current.bytes + byte_size(frame),
                  identity: identity,
                  crc_state: CRC32C.update(current.crc_state, frame)
              }

              {:cont, {:ok, next_logical, next, bytes + byte_size(frame)}}
            else
              error -> {:halt, error}
            end

          _, _ ->
            {:halt, {:error, :online_delta_record}}
        end)
        |> case do
          {:ok, logical, current, bytes} ->
            {:ok, logical.jobs, current, bytes, switch_started}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp write_manifest(native, bytes) do
    with {:ok, _} <- Native.create_stage(native, :candidate, "MANIFEST"),
         {:ok, _} <- Native.write(native, 0, bytes),
         :ok <- Native.sync(native),
         :ok <- Native.close_write(native),
         :ok <- Native.sync_dir(native, :candidate) do
      :ok
    end
  end

  defp manifest(source, inventory, epoch_id, base, tail_id, tail_first) do
    %{
      store_id: source.store_id,
      epoch_id: epoch_id,
      source_epoch_id: source.epoch_id,
      source_frontier: inventory.frontier,
      captured_at: source.captured_at,
      terminal_retention: source.terminal_retention,
      source_segments: inventory.sealed,
      base_segments: base,
      tail_segment_id: tail_id,
      tail_first_sequence: tail_first
    }
  end

  defp before_current(native, %{epoch_id: nil} = source, _epoch_id) do
    legacy = new_id()

    with {:ok, intent} <- Authority.encode_adoption(legacy),
         nonce <- new_id(),
         intent_stage <- ".tay-adoption-" <> Base.encode16(nonce, case: :lower) <> ".tmp",
         {:ok, intent_identity} <- Native.create_stage(native, :root, intent_stage),
         {:ok, _} <- Native.write(native, 0, intent),
         :ok <- Native.sync(native),
         :ok <- Native.close_write(native),
         :ok <- Native.publish(native, :root, intent_stage, "ADOPTION", intent_identity),
         :ok <- Native.sync_dir(native, :root),
         :ok <- Native.v2_adopt_v1(native, legacy),
         {:ok, marker} <- Authority.encode_marker(source.store_id),
         nonce <- new_id(),
         stage <- ".tay-v2-marker-" <> Base.encode16(nonce, case: :lower) <> ".tmp",
         {:ok, identity} <- Native.create_stage(native, :root, stage),
         {:ok, _} <- Native.write(native, 0, marker),
         :ok <- Native.sync(native),
         :ok <- Native.close_write(native),
         :ok <- Native.publish(native, :root, stage, "STORE-V2", identity),
         :ok <- Native.sync_dir(native, :root),
         do: :ok
  end

  defp before_current(native, source, _epoch_id) do
    with {:ok, entries} <- Native.list(native, :root),
         {:ok, bytes} <- current_bytes(native, entries),
         true <- bytes == source.current || {:error, :source_current_changed} do
      :ok
    end
  end

  defp stage_current(native, source, bytes) do
    with {:ok, entries} <- Native.list(native, :root),
         {:ok, previous} <- previous_current(entries, source),
         nonce <- new_id(),
         stage <- ".tay-current-" <> Base.encode16(nonce, case: :lower) <> ".tmp",
         {:ok, identity} <- Native.create_stage(native, :root, stage),
         {:ok, _} <- Native.write(native, 0, bytes),
         :ok <- Native.sync(native),
         :ok <- Native.close_write(native) do
      {:ok, stage, identity, previous}
    end
  end

  defp previous_current(entries, %{epoch_id: nil}) do
    if Enum.any?(entries, &(&1.name == "CURRENT")),
      do: {:error, :unexpected_current},
      else: {:ok, nil}
  end

  defp previous_current(entries, _source) do
    case Enum.find(entries, &(&1.name == "CURRENT")) do
      %{type: :regular, links: 1} = entry -> {:ok, entry}
      _ -> {:error, :current_missing}
    end
  end

  defp current_bytes(native, entries) do
    case Enum.find(entries, &(&1.name == "CURRENT")) do
      %{type: :regular, links: 1, size: 76} = entry ->
        with {:ok, opened} <- Native.open_read(native, :root, "CURRENT"),
             true <-
               (opened.device == entry.device and opened.inode == entry.inode) ||
                 {:error, :current_identity},
             {:ok, bytes} <- Native.read(native, 0, 76),
             :ok <- Native.close_read(native) do
          {:ok, bytes}
        end

      _ ->
        {:error, :current_missing}
    end
  end

  defp verify_published(
         native,
         source,
         normalized,
         limits,
         value_limits,
         publication
       ) do
    epoch_id = publication.epoch_id
    native = %{native | deadline: nil}

    result =
      with :ok <- Native.v2_select(native, epoch_id),
           {:ok, recovered} <-
             V2Reader.recover(native, Reducer.candidate(limits, value_limits), selected: true),
           true <-
             Snapshot.equivalent?(normalized, recovered.candidate.jobs) ||
               {:error, :published_candidate_mismatch} do
        {:ok,
         %{
           epoch_id: epoch_id,
           recovered: recovered,
           source_bytes: publication.source_bytes,
           candidate_bytes: publication.candidate_bytes,
           admitted_candidate_bytes: publication.admitted_candidate_bytes,
           peak_writer_process_bytes:
             max(publication.peak_writer_process_bytes, process_memory()),
           pause_ms: System.monotonic_time(:millisecond) - publication.switch_started,
           reclamation: :deferred,
           previous_epoch_id: source.epoch_id,
           terminal_retention: publication.terminal_retention,
           max_terminal_jobs: publication.max_terminal_jobs,
           captured_at: publication.captured_at,
           expired_jobs: publication.expired_jobs,
           pressure_expired_jobs: publication.pressure_expired_jobs,
           retained_terminal_jobs: publication.retained_terminal_jobs,
           reclaimed_bytes: 0
         }}
      end

    result
  end

  defp process_memory do
    case Process.info(self(), :memory) do
      {:memory, bytes} -> bytes
      _ -> 0
    end
  end

  if Mix.env() == :test do
    defp boundary(%{on_boundary: fun}, tag), do: fun.(tag)
    defp boundary(_, _), do: :ok
  else
    defp boundary(_, _), do: :ok
  end

  defp deadline_ok(nil),
    do:
      if(Tay.Storage.V2.CompactionControl.cancelled?(),
        do: {:error, :compaction_cancelled},
        else: :ok
      )

  defp deadline_ok(deadline) do
    if not Tay.Storage.V2.CompactionControl.cancelled?() and
         System.monotonic_time(:millisecond) < deadline,
       do: :ok,
       else: {:error, :compaction_deadline}
  end
end
