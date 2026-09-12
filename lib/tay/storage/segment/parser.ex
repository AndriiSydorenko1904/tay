defmodule Tay.Storage.Segment.Parser do
  @moduledoc false
  alias Tay.Storage.{CRC32C, Record, Segment}

  @spec scan(any(), any(), any()) ::
          {:error,
           %{
             :kind =>
               :ambiguous_short_tail
               | :corrupt_footer
               | :corrupt_segment_header
               | :id_or_store_mismatch
               | :incomplete_footer
               | :incomplete_record
               | :incomplete_segment_header
               | :invalid_argument
               | :io_or_resource_error
               | :record_or_sequence_error
               | :sealed_history_error
               | :segment_crc
               | :unsupported_segment_version,
             :offset => non_neg_integer(),
             :segment_id => any(),
             optional(:available_bytes) => number(),
             optional(:expected_bytes) => pos_integer(),
             optional(:reason) => any()
           }}
          | {:ok,
             %Tay.Storage.Segment{
               bytes: number(),
               count: non_neg_integer(),
               crc_state: non_neg_integer(),
               first_sequence: non_neg_integer(),
               footer: nil | map(),
               id: non_neg_integer(),
               identity: nil,
               last_sequence: nil | pos_integer(),
               state: :active | :sealed,
               store_id: <<_::128>>
             }}
          | {:ok,
             %Tay.Storage.Segment{
               bytes: number(),
               count: non_neg_integer(),
               crc_state: non_neg_integer(),
               first_sequence: non_neg_integer(),
               footer: nil | map(),
               id: non_neg_integer(),
               identity: nil,
               last_sequence: nil | pos_integer(),
               state: :active | :sealed,
               store_id: <<_::128>>
             }, any()}
  def scan(read, size, options) do
    case reduce(read, size, nil, fn _, _, acc -> acc end, options) do
      {:ok, segment, nil} -> {:ok, segment}
      error -> error
    end
  end

  @spec reduce(any(), any(), any(), any(), any()) ::
          {:error,
           %{
             :kind =>
               :ambiguous_short_tail
               | :corrupt_footer
               | :corrupt_segment_header
               | :id_or_store_mismatch
               | :incomplete_footer
               | :incomplete_record
               | :incomplete_segment_header
               | :invalid_argument
               | :io_or_resource_error
               | :record_or_sequence_error
               | :sealed_history_error
               | :segment_crc
               | :unsupported_segment_version,
             :offset => non_neg_integer(),
             :segment_id => any(),
             optional(:available_bytes) => number(),
             optional(:expected_bytes) => pos_integer(),
             optional(:reason) => any()
           }}
          | {:ok,
             %Tay.Storage.Segment{
               bytes: number(),
               count: non_neg_integer(),
               crc_state: non_neg_integer(),
               first_sequence: non_neg_integer(),
               footer: nil | map(),
               id: non_neg_integer(),
               identity: nil,
               last_sequence: nil | pos_integer(),
               state: :active | :sealed,
               store_id: <<_::128>>
             }, any()}
  def reduce(read, size, accumulator, reducer, options) do
    if is_function(read, 2) and is_integer(size) and size >= 0 and
         is_function(reducer, 3) and valid_options?(options) do
      context = %{
        read: read,
        size: size,
        options: options,
        reducer: reducer,
        id: Keyword.get(options, :id),
        highest: Keyword.get(options, :highest, true)
      }

      case read_at(context, 0, 44) do
        {:ok, header} -> start(context, header, accumulator)
        {:error, reason} -> fail(context, :io_or_resource_error, 0, reason)
      end
    else
      {:error, %{kind: :invalid_argument, segment_id: nil, offset: 0}}
    end
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(options, fn
        {:id, id} -> is_integer(id) and id in 1..18_446_744_073_709_551_615
        {:store_id, id} -> is_binary(id) and byte_size(id) == 16 and id != <<0::128>>
        {:highest, highest} -> is_boolean(highest)
        {:max_decode_payload_bytes, n} -> is_integer(n) and n in 0..16_777_216
        _ -> false
      end)
  end

  defp start(ctx, header, accumulator) do
    expected = ctx.options |> Keyword.take([:id, :store_id]) |> Map.new()

    case Segment.decode_header(header, expected) do
      {:ok, segment} ->
        ctx = %{ctx | id: segment.id}

        if ctx.size > Segment.max_bytes() do
          fail(ctx, :corrupt_segment_header, 0, :segment_size_exceeds_format)
        else
          next(ctx, %{segment | crc_state: CRC32C.update(CRC32C.initial(), header)}, accumulator)
        end

      {:incomplete, needed} ->
        incomplete(ctx, :incomplete_segment_header, 0, byte_size(header), needed)

      {:error, {:unsupported_version, _} = reason} ->
        fail(ctx, :unsupported_segment_version, 0, reason)

      {:error, {:unsupported_flags, _} = reason} ->
        fail(ctx, :unsupported_segment_flags, 0, reason)

      {:error, {:mismatch, _, _, _} = reason} ->
        fail(ctx, :id_or_store_mismatch, 0, reason)

      {:error, reason} ->
        fail(ctx, :corrupt_segment_header, 0, reason)
    end
  end

  defp next(ctx, segment, accumulator) do
    offset = segment.bytes

    case read_at(ctx, offset, 4) do
      {:ok, <<>>} ->
        cond do
          not ctx.highest ->
            fail(ctx, :sealed_history_error, offset, :earlier_active_segment)

          ctx.size > Segment.max_bytes() - 64 ->
            fail(ctx, :record_or_sequence_error, offset, :active_size_exceeds_format)

          true ->
            {:ok, %{segment | state: :active}, accumulator}
        end

      {:ok, "TAYF"} ->
        finish(ctx, segment, accumulator)

      {:ok, <<"TAY", 0>>} ->
        record(ctx, segment, accumulator)

      {:ok, short} when byte_size(short) < 4 ->
        if short == binary_part("TAY", 0, byte_size(short)),
          do: incomplete(ctx, :ambiguous_short_tail, offset, byte_size(short), 4),
          else: fail(ctx, :record_or_sequence_error, offset, {:error, {:corrupt, :invalid_magic}})

      {:ok, _} ->
        fail(ctx, :record_or_sequence_error, offset, {:error, {:corrupt, :invalid_magic}})

      {:error, reason} ->
        fail(ctx, :io_or_resource_error, offset, reason)
    end
  end

  defp record(ctx, segment, accumulator) do
    options = Keyword.take(ctx.options, [:max_decode_payload_bytes])

    with {:ok, header} <- read_at(ctx, segment.bytes, 24) do
      case Record.decode(header, options) do
        {:incomplete, stage, metadata} when stage in [:payload, :checksum] ->
          case read_at(ctx, segment.bytes, metadata.record_bytes) do
            {:ok, bytes} ->
              accept_record(ctx, segment, accumulator, bytes, Record.decode(bytes, options))

            {:error, reason} ->
              fail(ctx, :io_or_resource_error, segment.bytes, reason)
          end

        other ->
          record_failure(ctx, segment.bytes, byte_size(header), other)
      end
    else
      {:error, reason} -> fail(ctx, :io_or_resource_error, segment.bytes, reason)
    end
  end

  defp accept_record(ctx, segment, accumulator, bytes, {:ok, record, <<>>}) do
    expected = segment.first_sequence + segment.count

    cond do
      record.sequence != expected ->
        fail(
          ctx,
          :record_or_sequence_error,
          segment.bytes,
          {:sequence, expected, record.sequence}
        )

      segment.count >= Segment.max_count() ->
        fail(ctx, :record_or_sequence_error, segment.bytes, :record_count_exceeds_format)

      true ->
        accumulator = ctx.reducer.(record, segment.bytes, accumulator)

        updated = %{
          segment
          | last_sequence: record.sequence,
            count: segment.count + 1,
            bytes: segment.bytes + byte_size(bytes),
            crc_state: CRC32C.update(segment.crc_state, bytes)
        }

        next(ctx, updated, accumulator)
    end
  end

  defp accept_record(ctx, segment, _acc, bytes, result),
    do: record_failure(ctx, segment.bytes, byte_size(bytes), result)

  defp record_failure(ctx, offset, available, {:incomplete, :header} = result),
    do: incomplete(ctx, :incomplete_record, offset, available, 24, result)

  defp record_failure(ctx, offset, available, {:incomplete, _, metadata} = result),
    do: incomplete(ctx, :incomplete_record, offset, available, metadata.record_bytes, result)

  defp record_failure(ctx, offset, _available, {:error, {:resource_limit, _, _}} = result),
    do: fail(ctx, :io_or_resource_error, offset, result)

  defp record_failure(ctx, offset, _available, result),
    do: fail(ctx, :record_or_sequence_error, offset, result)

  defp finish(ctx, segment, accumulator) do
    remaining = ctx.size - segment.bytes

    cond do
      remaining < 64 ->
        incomplete(ctx, :incomplete_footer, segment.bytes, remaining, 64)

      remaining > 64 ->
        fail(ctx, :corrupt_footer, segment.bytes, :trailing_footer_bytes)

      true ->
        case read_at(ctx, segment.bytes, 64) do
          {:ok, bytes} ->
            expected = %{
              id: segment.id,
              first_sequence: segment.first_sequence,
              store_id: segment.store_id,
              count: segment.count,
              last_sequence: segment.last_sequence,
              segment_crc: CRC32C.finalize(segment.crc_state)
            }

            case Segment.decode_footer(bytes, expected) do
              {:ok, footer} ->
                {:ok, %{segment | state: :sealed, footer: footer, bytes: ctx.size}, accumulator}

              {:error, {:unsupported_version, _} = reason} ->
                fail(ctx, :unsupported_segment_version, segment.bytes, reason)

              {:error, {:unsupported_flags, _} = reason} ->
                fail(ctx, :unsupported_segment_flags, segment.bytes, reason)

              {:error, {:mismatch, :segment_crc, _, _} = reason} ->
                fail(ctx, :segment_crc, segment.bytes, reason)

              {:error, reason} ->
                fail(ctx, :corrupt_footer, segment.bytes, reason)
            end

          {:error, reason} ->
            fail(ctx, :io_or_resource_error, segment.bytes, reason)
        end
    end
  end

  defp read_at(ctx, offset, limit) do
    length = min(limit, max(ctx.size - offset, 0))

    case ctx.read.(offset, length) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _} -> {:error, :changed_file_or_short_read}
      {:error, _} = error -> error
      _ -> {:error, :invalid_read_result}
    end
  end

  defp incomplete(ctx, kind, offset, available, expected, reason \\ nil) do
    classification = if ctx.highest, do: kind, else: :sealed_history_error

    {:error,
     %{
       kind: classification,
       reason: reason || kind,
       segment_id: ctx.id,
       offset: offset,
       available_bytes: available,
       expected_bytes: expected
     }}
  end

  defp fail(ctx, kind, offset, reason),
    do: {:error, %{kind: kind, reason: reason, segment_id: ctx.id, offset: offset}}
end
