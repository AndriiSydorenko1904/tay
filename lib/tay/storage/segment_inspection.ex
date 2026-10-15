defmodule Tay.Storage.SegmentInspection do
  @moduledoc false

  alias Tay.Storage.{Native, Record, RecordInspection, Segment}

  @segment_header_bytes 44
  @segment_footer_bytes 64
  @record_header_bytes 24

  def page(native, snapshot, segment_id, cursor, limit, cache \\ nil) do
    with_segment(native, snapshot, segment_id, fn context ->
      offset = cursor || @segment_header_bytes

      with true <- valid_cursor?(offset, context.data_end) || {:error, :invalid_cursor},
           {:ok, records, next_offset} <-
             read_page(native, context, offset, limit, cache, []) do
        next_cursor = if next_offset < context.data_end, do: next_offset

        {:ok,
         %{
           records: Enum.reverse(records),
           total_count: context.total_count,
           cursor: cursor,
           next_cursor: next_cursor,
           truncated: not is_nil(next_cursor)
         }}
      end
    end)
  end

  def detail(native, snapshot, segment_id, offset, sequence) do
    with_segment(native, snapshot, segment_id, fn context ->
      with true <- valid_cursor?(offset, context.data_end - 1) || {:error, :invalid_offset},
           {:ok, record, _next_offset} <- read_record(native, context.data_end, offset),
           true <- record.sequence == sequence || {:error, :record_mismatch} do
        {:ok, RecordInspection.describe(record)}
      end
    end)
  end

  defp with_segment(native, snapshot, segment_id, fun) do
    with {:ok, name} <- Segment.filename(segment_id),
         {:ok, entries} <- Native.list(native, :segments),
         {:ok, entry} <- fetch_entry(entries, name),
         {:ok, identity} <- Native.open_read(native, :segments, name) do
      result =
        with :ok <- same_file(entry, identity, snapshot, segment_id),
             {:ok, context} <- context(native, snapshot, segment_id, identity) do
          fun.(context)
        end

      case {result, Native.close_read(native)} do
        {{:ok, _} = success, :ok} -> success
        {{:error, _} = error, _close} -> error
        {_result, {:error, _} = error} -> error
      end
    end
  end

  defp context(native, snapshot, segment_id, identity) do
    active? = snapshot.active_segment.id == segment_id

    data_end =
      if active?,
        do: snapshot.active_segment.bytes,
        else: identity.size - @segment_footer_bytes

    with true <- data_end >= @segment_header_bytes || {:error, :invalid_segment_size},
         {:ok, header} when byte_size(header) == @segment_header_bytes <-
           Native.read(native, 0, @segment_header_bytes),
         {:ok, _segment} <-
           Segment.decode_header(header, %{id: segment_id, store_id: snapshot.store_id}),
         {:ok, total_count} <- total_count(native, snapshot, segment_id, identity.size, active?) do
      {:ok,
       %{
         data_end: data_end,
         identity: identity,
         segment_id: segment_id,
         total_count: total_count
       }}
    else
      {:ok, _short} -> {:error, :short_segment_header}
      error -> error
    end
  end

  defp total_count(_native, snapshot, segment_id, _size, true),
    do:
      if(snapshot.active_segment.id == segment_id,
        do: {:ok, snapshot.active_segment.count},
        else: {:error, :segment_changed}
      )

  defp total_count(native, snapshot, segment_id, size, false) do
    with true <-
           size >= @segment_header_bytes + @segment_footer_bytes ||
             {:error, :incomplete_footer},
         {:ok, bytes} when byte_size(bytes) == @segment_footer_bytes <-
           Native.read(native, size - @segment_footer_bytes, @segment_footer_bytes),
         {:ok, footer} <-
           Segment.decode_footer(bytes, %{id: segment_id, store_id: snapshot.store_id}) do
      {:ok, footer.count}
    else
      {:ok, _short} -> {:error, :short_footer_read}
      error -> error
    end
  end

  defp read_page(_native, context, offset, _remaining, _cache, records)
       when offset == context.data_end,
       do: {:ok, records, offset}

  defp read_page(_native, _context, offset, 0, _cache, records),
    do: {:ok, records, offset}

  defp read_page(native, context, offset, remaining, cache, records) do
    with {:ok, record, next_offset} <- read_record(native, context.data_end, offset) do
      key =
        {context.identity.device, context.identity.inode, offset, record.sequence,
         byte_size(record.payload)}

      inspection = cached_preview(cache, key, record)

      entry = %{
        sequence: record.sequence,
        offset: offset,
        record_type: record.record_type,
        payload_schema_version: record.payload_schema_version,
        payload_bytes: byte_size(record.payload),
        inspection: inspection
      }

      read_page(native, context, next_offset, remaining - 1, cache, [entry | records])
    end
  end

  defp read_record(native, data_end, offset) do
    available = data_end - offset

    with true <- available >= @record_header_bytes || {:error, :incomplete_record_header},
         {:ok, header} when byte_size(header) == @record_header_bytes <-
           Native.read(native, offset, @record_header_bytes),
         {:incomplete, stage, metadata} when stage in [:payload, :checksum] <-
           Record.decode(header),
         true <- metadata.record_bytes <= available || {:error, :incomplete_record},
         {:ok, bytes} when byte_size(bytes) == metadata.record_bytes <-
           Native.read(native, offset, metadata.record_bytes),
         {:ok, record, <<>>} <- Record.decode(bytes) do
      {:ok, record, offset + metadata.record_bytes}
    else
      {:ok, _short} -> {:error, :short_record_read}
      {:error, _} = error -> error
      other -> {:error, {:invalid_record, other}}
    end
  end

  defp cached_preview(nil, _key, record), do: RecordInspection.preview(record)

  defp cached_preview(cache, key, record) do
    case :ets.lookup(cache, key) do
      [{^key, preview}] ->
        preview

      [] ->
        preview = RecordInspection.preview(record)
        cache_preview(cache, key, preview)
        preview
    end
  rescue
    ArgumentError -> RecordInspection.preview(record)
  end

  defp cache_preview(cache, key, preview) do
    if :ets.info(cache, :size) >= 512, do: :ets.delete_all_objects(cache)
    :ets.insert(cache, {key, preview})
  end

  defp valid_cursor?(offset, data_end),
    do: is_integer(offset) and offset >= @segment_header_bytes and offset <= data_end

  defp fetch_entry(entries, name) do
    case Enum.find(entries, &(&1.name == name)) do
      nil -> {:error, :segment_not_found}
      entry -> {:ok, entry}
    end
  end

  defp same_file(entry, identity, snapshot, segment_id) do
    same_identity = entry.device == identity.device and entry.inode == identity.inode

    stable_size =
      if snapshot.active_segment.id == segment_id,
        do:
          entry.size >= snapshot.active_segment.bytes and
            identity.size >= snapshot.active_segment.bytes,
        else: entry.size == identity.size

    if same_identity and stable_size, do: :ok, else: {:error, :segment_changed}
  end
end
