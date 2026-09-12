defmodule Tay.Storage.Segment do
  @moduledoc """
  Physical v1 segment container. See the Phase 2 segment RFC for the byte contract.

  Checksums, framing, and sequence continuity establish physical integrity only.
  No result authorizes repair, semantic replay, or an applied checkpoint.
  """
  alias Tay.Storage.CRC32C

  @max_id 18_446_744_073_709_551_615
  @max_bytes 1_073_741_824
  @max_count 38_347_918
  defstruct [
    :id,
    :first_sequence,
    :store_id,
    :state,
    :last_sequence,
    :crc_state,
    :footer,
    :identity,
    count: 0,
    bytes: 44
  ]

  @spec max_id() :: 18_446_744_073_709_551_615
  def max_id, do: @max_id

  @spec max_bytes() :: 1_073_741_824
  def max_bytes, do: @max_bytes

  @spec min_rotation_bytes() :: 16_777_352
  def min_rotation_bytes, do: 16_777_352

  @spec max_count() :: 38_347_918
  def max_count, do: @max_count

  @doc "Halt-aware physical traversal; errors never return a successful prefix accumulator."
  def reduce_while(read, size, accumulator, visitor, options \\ []),
    do: Tay.Storage.Segment.Parser.reduce_while(read, size, accumulator, visitor, options)

  @spec parse(binary()) ::
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
               | :unsupported_segment_flags
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
  @doc "Validates a complete in-memory segment without retaining its records."
  def parse(bytes, options \\ []) when is_binary(bytes) do
    read = fn offset, length -> {:ok, binary_part(bytes, offset, length)} end
    scan(read, byte_size(bytes), options)
  end

  @spec scan(any(), any()) ::
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
               | :unsupported_segment_flags
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
  @doc "Validates a segment through bounded positional reads. No writes occur."
  def scan(read, size, options \\ []),
    do: Tay.Storage.Segment.Parser.scan(read, size, options)

  @spec reduce(any(), any(), any(), any()) ::
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
               | :unsupported_segment_flags
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
  @doc "Physical reduction; accumulator is returned only on complete success."
  def reduce(read, size, accumulator, reducer, options \\ []),
    do: Tay.Storage.Segment.Parser.reduce(read, size, accumulator, reducer, options)

  @spec filename(any()) :: {:error, :invalid_segment_id} | {:ok, <<_::32, _::_*8>>}
  def filename(id) when is_integer(id) and id in 1..@max_id,
    do: {:ok, String.pad_leading(Integer.to_string(id), 20, "0") <> ".tay"}

  def filename(_), do: {:error, :invalid_segment_id}

  @spec filename_id(any()) ::
          {:error, :invalid_segment_id | :invalid_segment_name} | {:ok, integer()}
  def filename_id(name) when is_binary(name) do
    if byte_size(name) == 24 and Regex.match?(~r/\A[0-9]{20}\.tay\z/, name) do
      {id, ".tay"} = Integer.parse(name)
      if id in 1..@max_id, do: {:ok, id}, else: {:error, :invalid_segment_id}
    else
      {:error, :invalid_segment_name}
    end
  end

  def filename_id(_), do: {:error, :invalid_segment_name}

  @spec encode_store(any()) :: {:error, :invalid_store_id} | {:ok, <<_::32, _::_*8>>}
  def encode_store(store_id) do
    if valid_store_id?(store_id) do
      {:ok, checked(<<"TAYI", 1, 0, 0::16, store_id::binary>>)}
    else
      {:error, :invalid_store_id}
    end
  end

  @spec decode_store(any()) ::
          false
          | <<_::64, _::_*8>>
          | {:error,
             :checksum
             | :invalid_argument
             | :invalid_magic
             | :invalid_store_id
             | :reserved_bytes
             | :trailing_store_bytes
             | {:invalid_version, 0}
             | {:unsupported_flags, byte()}
             | {:unsupported_version, byte()}}
          | {:incomplete, 28 | 44 | 64}
          | {:ok, <<_::128>>}
  def decode_store(bytes) when is_binary(bytes) do
    with {:ok, body} <- fixed(bytes, "TAYI", 28),
         true <- byte_size(bytes) == 28 || {:error, :trailing_store_bytes},
         <<_::binary-size(8), store_id::binary-size(16)>> <- body,
         true <- valid_store_id?(store_id) || {:error, :invalid_store_id} do
      {:ok, store_id}
    end
  end

  def decode_store(_), do: {:error, :invalid_argument}

  @spec encode_header(any()) ::
          {:error,
           :invalid_argument | :invalid_first_sequence | :invalid_segment_id | :invalid_store_id}
          | {:ok, <<_::32, _::_*8>>}
  def encode_header(%{id: id, first_sequence: first, store_id: store_id}) do
    cond do
      not uint64?(id) -> {:error, :invalid_segment_id}
      not uint64?(first) -> {:error, :invalid_first_sequence}
      not valid_store_id?(store_id) -> {:error, :invalid_store_id}
      true -> {:ok, checked(<<"TAYS", 1, 0, 0::16, id::64, first::64, store_id::binary>>)}
    end
  end

  def encode_header(_), do: {:error, :invalid_argument}

  @spec decode_header(any()) ::
          false
          | <<_::64, _::_*8>>
          | {:error,
             :checksum
             | :invalid_argument
             | :invalid_first_sequence
             | :invalid_magic
             | :invalid_segment_id
             | :invalid_store_id
             | :reserved_bytes
             | {:invalid_version, 0}
             | {:unsupported_flags, byte()}
             | {:unsupported_version, byte()}
             | {:mismatch,
                :count | :first_sequence | :id | :last_sequence | :segment_crc | :store_id, any(),
                <<_::128>> | non_neg_integer()}}
          | {:incomplete, 28 | 44 | 64}
          | {:ok,
             %Tay.Storage.Segment{
               bytes: 44,
               count: 0,
               crc_state: nil,
               first_sequence: non_neg_integer(),
               footer: nil,
               id: non_neg_integer(),
               identity: nil,
               last_sequence: nil,
               state: nil,
               store_id: <<_::128>>
             }}
  def decode_header(bytes, expected \\ %{})

  def decode_header(bytes, expected) when is_binary(bytes) and is_map(expected) do
    with {:ok, body} <- fixed(bytes, "TAYS", 44),
         <<_::binary-size(8), id::64, first::64, store_id::binary-size(16)>> <- body,
         true <- uint64?(id) || {:error, :invalid_segment_id},
         true <- uint64?(first) || {:error, :invalid_first_sequence},
         true <- valid_store_id?(store_id) || {:error, :invalid_store_id},
         :ok <- equal(expected, :id, id),
         :ok <- equal(expected, :store_id, store_id) do
      {:ok, %__MODULE__{id: id, first_sequence: first, store_id: store_id}}
    end
  end

  def decode_header(_, _), do: {:error, :invalid_argument}

  @spec encode_footer(any()) ::
          false
          | {:error,
             :count_sequence_relation
             | :invalid_argument
             | :invalid_crc
             | :invalid_first_sequence
             | :invalid_last_sequence
             | :invalid_record_count
             | :invalid_segment_id
             | :invalid_store_id}
          | {:ok, <<_::32, _::_*8>>}
  def encode_footer(
        %{
          id: id,
          first_sequence: first,
          last_sequence: last,
          count: count,
          store_id: store_id,
          segment_crc: crc
        } = footer
      ) do
    with :ok <- footer_values(footer),
         true <- last == first + count - 1 || {:error, :count_sequence_relation} do
      {:ok,
       checked(
         <<"TAYF", 1, 0, 0::16, id::64, first::64, last::64, count::64, store_id::binary,
           crc::32>>
       )}
    end
  end

  def encode_footer(_), do: {:error, :invalid_argument}

  @spec decode_footer(any()) ::
          false
          | {:error,
             :checksum
             | :count_sequence_relation
             | :invalid_argument
             | :invalid_crc
             | :invalid_first_sequence
             | :invalid_last_sequence
             | :invalid_magic
             | :invalid_record_count
             | :invalid_segment_id
             | :invalid_store_id
             | :reserved_bytes
             | :trailing_footer_bytes
             | {:invalid_version, 0}
             | {:unsupported_flags, byte()}
             | {:unsupported_version, byte()}
             | {:mismatch,
                :count | :first_sequence | :id | :last_sequence | :segment_crc | :store_id, any(),
                <<_::128>> | non_neg_integer()}}
          | {:incomplete, 28 | 44 | 64}
          | {:ok,
             %{
               count: non_neg_integer(),
               first_sequence: non_neg_integer(),
               id: non_neg_integer(),
               last_sequence: non_neg_integer(),
               segment_crc: non_neg_integer(),
               store_id: <<_::128>>
             }}
  def decode_footer(bytes, expected \\ %{})

  def decode_footer(bytes, expected) when is_binary(bytes) and is_map(expected) do
    with {:ok, body} <- fixed(bytes, "TAYF", 64),
         true <- byte_size(bytes) == 64 || {:error, :trailing_footer_bytes} do
      <<_::binary-size(8), id::64, first::64, last::64, count::64, store_id::binary-size(16),
        crc::32>> = body

      footer = %{
        id: id,
        first_sequence: first,
        last_sequence: last,
        count: count,
        store_id: store_id,
        segment_crc: crc
      }

      with :ok <- footer_values(footer, false),
           :ok <- equal(expected, :id, id),
           :ok <- equal(expected, :first_sequence, first),
           true <- valid_store_id?(store_id) || {:error, :invalid_store_id},
           :ok <- equal(expected, :store_id, store_id),
           true <-
             (first + count - 1 <= @max_id and last == first + count - 1) ||
               {:error, :count_sequence_relation},
           :ok <- equal(expected, :count, count),
           :ok <- equal(expected, :last_sequence, last),
           :ok <- equal(expected, :segment_crc, crc) do
        {:ok, footer}
      end
    end
  end

  def decode_footer(_, _), do: {:error, :invalid_argument}

  defp footer_values(f, check_store \\ true) do
    cond do
      not uint64?(f.id) ->
        {:error, :invalid_segment_id}

      not uint64?(f.first_sequence) ->
        {:error, :invalid_first_sequence}

      not uint64?(f.last_sequence) ->
        {:error, :invalid_last_sequence}

      not is_integer(f.count) or f.count not in 1..@max_count ->
        {:error, :invalid_record_count}

      check_store and not valid_store_id?(f.store_id) ->
        {:error, :invalid_store_id}

      not is_integer(f.segment_crc) or f.segment_crc not in 0..0xFFFFFFFF ->
        {:error, :invalid_crc}

      true ->
        :ok
    end
  end

  defp fixed(bytes, magic, size) do
    prefix = min(byte_size(bytes), 4)

    cond do
      binary_part(bytes, 0, prefix) != binary_part(magic, 0, prefix) ->
        {:error, :invalid_magic}

      byte_size(bytes) < 5 ->
        {:incomplete, size}

      :binary.at(bytes, 4) == 0 ->
        {:error, {:invalid_version, 0}}

      :binary.at(bytes, 4) != 1 ->
        {:error, {:unsupported_version, :binary.at(bytes, 4)}}

      byte_size(bytes) < size ->
        {:incomplete, size}

      true ->
        n = size - 4
        <<body::binary-size(^n), crc::32, _::binary>> = bytes

        cond do
          CRC32C.checksum(body) != crc -> {:error, :checksum}
          :binary.at(body, 5) != 0 -> {:error, {:unsupported_flags, :binary.at(body, 5)}}
          binary_part(body, 6, 2) != <<0, 0>> -> {:error, :reserved_bytes}
          true -> {:ok, body}
        end
    end
  end

  defp checked(body), do: <<body::binary, CRC32C.checksum(body)::32>>
  defp uint64?(n), do: is_integer(n) and n in 1..@max_id
  defp valid_store_id?(id), do: is_binary(id) and byte_size(id) == 16 and id != <<0::128>>

  defp equal(expected, key, value) do
    case Map.fetch(expected, key) do
      :error -> :ok
      {:ok, ^value} -> :ok
      {:ok, other} -> {:error, {:mismatch, key, other, value}}
    end
  end
end
