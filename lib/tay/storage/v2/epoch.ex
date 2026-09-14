defmodule Tay.Storage.V2.Epoch do
  @moduledoc """
  Pure Store-v2 epoch construction and semantic replay over supplied bytes.
  Filesystem ownership, digest pinning and CURRENT publication are deliberately
  outside this module; callers must supply fully pinned segment contents.
  """

  alias Tay.Event.V1
  alias Tay.Storage.{CRC32C, Reader, Record, Segment}
  alias Tay.Storage.V2.{Codec, Reducer, Snapshot}

  def build(jobs, store_id) when is_map(jobs) do
    with true <- V1.id?(store_id) || {:error, :store_id},
         {:ok, snapshots, stats} <- Snapshot.plan(jobs, :infinity),
         {:ok, base} <- pack_snapshots(snapshots, store_id),
         tail_id <- length(base) + 1,
         tail_first <- length(snapshots) + 1,
         {:ok, tail} <-
           Segment.encode_header(%{id: tail_id, first_sequence: tail_first, store_id: store_id}),
         {:ok, recovered} <- recover(Enum.map(base, & &1.bytes), [tail], store_id),
         true <- Snapshot.equivalent?(jobs, recovered.jobs) || {:error, :candidate_mismatch} do
      {:ok,
       %{
         base: base,
         tail: tail,
         tail_segment_id: tail_id,
         tail_first_sequence: tail_first,
         next_availability_order: stats.next_availability_order,
         retained_jobs: map_size(jobs)
       }}
    end
  end

  def build(_, _), do: {:error, :invalid_jobs}

  def recover(base_bytes, tail_bytes, store_id)
      when is_list(base_bytes) and is_list(tail_bytes) and tail_bytes != [] do
    all = base_bytes ++ tail_bytes
    base_count = length(base_bytes)
    total = length(all)

    with true <- V1.id?(store_id) || {:error, :store_id},
         {:ok, segments} <- parse_all(all, store_id, total),
         :ok <- topology(segments, base_count),
         {:ok, candidate, _next, _id} <- replay_all(all, store_id, base_count) do
      {:ok, candidate}
    end
  end

  def recover(_, _, _), do: {:error, :invalid_segments}

  defp pack_snapshots([], _), do: {:ok, []}

  defp pack_snapshots(snapshots, store_id) do
    Enum.with_index(snapshots, 1)
    |> Enum.reduce_while({:ok, nil, []}, fn {payload, sequence}, {:ok, current, sealed} ->
      record = %Record{
        record_type: Codec.snapshot_type(),
        payload_schema_version: Codec.schema(),
        sequence: sequence,
        payload: payload
      }

      with {:ok, bytes} <- Record.encode(record),
           true <-
             byte_size(bytes) + 44 + 64 <= Segment.max_bytes() ||
               {:error, :snapshot_exceeds_segment},
           {:ok, current, sealed} <- room(current, sealed, bytes, sequence, store_id),
           {:ok, current} <- add_record(current, bytes) do
        {:cont, {:ok, current, sealed}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, current, sealed} ->
        with {:ok, last} <- seal(current), do: {:ok, Enum.reverse([last | sealed])}

      error ->
        error
    end
  end

  defp room(nil, sealed, _, sequence, store_id),
    do: with({:ok, fresh} <- new_segment(1, sequence, store_id), do: {:ok, fresh, sealed})

  defp room(current, sealed, bytes, sequence, store_id) do
    if current.size + byte_size(bytes) + 64 <= Segment.max_bytes() do
      {:ok, current, sealed}
    else
      with {:ok, finished} <- seal(current),
           {:ok, fresh} <- new_segment(current.id + 1, sequence, store_id) do
        {:ok, fresh, [finished | sealed]}
      end
    end
  end

  defp new_segment(id, first, store_id) do
    with {:ok, header} <-
           Segment.encode_header(%{id: id, first_sequence: first, store_id: store_id}) do
      {:ok,
       %{
         id: id,
         first_sequence: first,
         last_sequence: nil,
         count: 0,
         header: header,
         records: [],
         size: 44,
         crc: CRC32C.update(CRC32C.initial(), header),
         store_id: store_id
       }}
    end
  end

  defp add_record(current, bytes) do
    {:ok,
     %{
       current
       | records: [bytes | current.records],
         count: current.count + 1,
         last_sequence: current.first_sequence + current.count,
         size: current.size + byte_size(bytes),
         crc: CRC32C.update(current.crc, bytes)
     }}
  end

  defp seal(current) do
    footer = %{
      id: current.id,
      first_sequence: current.first_sequence,
      last_sequence: current.last_sequence,
      count: current.count,
      store_id: current.store_id,
      segment_crc: CRC32C.finalize(current.crc)
    }

    with {:ok, footer_bytes} <- Segment.encode_footer(footer) do
      bytes = IO.iodata_to_binary([current.header, Enum.reverse(current.records), footer_bytes])

      {:ok,
       %{
         id: current.id,
         first_sequence: current.first_sequence,
         last_sequence: current.last_sequence,
         bytes: bytes,
         digest: :crypto.hash(:sha256, bytes)
       }}
    end
  end

  defp parse_all(bytes, store_id, total) do
    Enum.with_index(bytes, 1)
    |> Enum.reduce_while({:ok, []}, fn {segment, id}, {:ok, acc} ->
      case Segment.parse(segment, id: id, store_id: store_id, highest: id == total) do
        {:ok, summary} -> {:cont, {:ok, [summary | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp topology(segments, base_count) do
    with {:ok, _} <- Reader.validate_topology(segments),
         true <-
           Enum.all?(Enum.take(segments, base_count), &(&1.state == :sealed)) ||
             {:error, :unsealed_base},
         true <-
           Enum.at(segments, base_count).first_sequence ==
             if(base_count == 0, do: 1, else: Enum.at(segments, base_count - 1).last_sequence + 1) ||
             {:error, :tail_frontier} do
      :ok
    end
  end

  defp replay_all(bytes, store_id, base_count) do
    Enum.with_index(bytes, 1)
    |> Enum.reduce_while({:ok, Reducer.candidate(), 1, nil}, fn {segment, id},
                                                                {:ok, candidate, sequence,
                                                                 last_id} ->
      read = fn offset, length -> {:ok, binary_part(segment, offset, length)} end

      visitor = fn record, _offset, {candidate, expected, previous_id} ->
        with true <- record.sequence == expected || {:error, :physical_sequence},
             true <-
               record.payload_schema_version == Codec.schema() ||
                 {:error, :payload_schema},
             {:ok, next, new_id} <-
               replay_record(record, id <= base_count, candidate, previous_id) do
          {:cont, {next, expected + 1, new_id}}
        end
      end

      case Segment.reduce_while(
             read,
             byte_size(segment),
             {candidate, sequence, last_id},
             visitor,
             id: id,
             store_id: store_id,
             highest: id == length(bytes)
           ) do
        {:ok, _summary, {next, expected, previous_id}} ->
          {:cont, {:ok, next, expected, previous_id}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp replay_record(%{record_type: 7, payload: payload}, true, candidate, previous_id) do
    with {:ok, job} <- Codec.decode_snapshot(payload),
         true <- (is_nil(previous_id) or job.id > previous_id) || {:error, :snapshot_order},
         {:ok, next} <- Reducer.insert_snapshot(candidate, job) do
      {:ok, next, job.id}
    end
  end

  defp replay_record(%{record_type: 8, payload: payload}, false, candidate, previous_id) do
    with {:ok, mutation} <- Codec.decode_mutation(payload),
         {:ok, next} <- Reducer.apply(candidate, mutation) do
      {:ok, next, previous_id}
    end
  end

  defp replay_record(_, _, _, _), do: {:error, :record_profile}
end
