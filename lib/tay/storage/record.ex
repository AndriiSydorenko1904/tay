defmodule Tay.Storage.Record do
  @moduledoc """
  Pure Tay v1 physical framing and integrity codec.

  The public contract is `docs/storage.md`: a 24-byte
  header, 28-byte overhead, big-endian integers, CRC32C over header bytes 0..19
  and over those bytes followed by the opaque payload, and a 16 MiB hard limit.

  Every type in 1..254 and schema in 1..255 is physically valid. Success does
  not establish sequence continuity, semantic acceptance, or an applied event.
  A physical cursor is not an applied replay checkpoint. Those checks belong
  to later layers, not this codec.

  Decoding examines one record at offset zero and returns the exact remainder
  only on success. Every other result consumes nothing. Incomplete data is
  only a parse classification, never permission or a recommendation to repair.
  No payload interpretation, I/O, processes, or sequence allocation occurs.
  """

  alias Tay.Storage.CRC32C

  @magic "TAY\x00"
  @hard_payload_max 16_777_216
  @uint64_max 18_446_744_073_709_551_615
  @enforce_keys [:record_type, :payload_schema_version, :sequence, :payload]
  defstruct [
    :record_type,
    :payload_schema_version,
    :sequence,
    :payload,
    format_version: 1,
    flags: 0
  ]

  @type t :: %__MODULE__{
          format_version: 1,
          record_type: 1..254,
          flags: 0,
          payload_schema_version: 1..255,
          sequence: 1..18_446_744_073_709_551_615,
          payload: binary()
        }
  @type domain_reason ::
          {:invalid_format, 0}
          | {:reserved_type, 0 | 255}
          | {:invalid_schema, 0}
          | {:invalid_sequence, 0}
          | {:payload_length_exceeds_format, non_neg_integer(), 16_777_216}
  @type corrupt_reason ::
          domain_reason() | :invalid_magic | :header_checksum | :record_checksum
  @type primitive_field ::
          :format_version | :record_type | :flags | :payload_schema_version | :sequence | :payload
  @type unsupported_reason :: {:format, 2..255} | {:flags, 1..255}
  @type option_error ::
          :not_keyword | :duplicate_keys | :unknown_keys | :invalid_max_decode_payload_bytes
  @type metadata :: %{
          format_version: 1,
          record_type: 1..254,
          flags: 0,
          payload_schema_version: 1..255,
          sequence: 1..18_446_744_073_709_551_615,
          payload_length: 0..16_777_216,
          record_bytes: 28..16_777_244,
          available_bytes: non_neg_integer(),
          missing_bytes: pos_integer()
        }
  @type decode_result ::
          {:ok, t(), binary()}
          | {:incomplete, :header}
          | {:incomplete, :payload | :checksum, metadata()}
          | {:error, {:corrupt, corrupt_reason()}}
          | {:error, {:unsupported, unsupported_reason()}}
          | {:error, {:resource_limit, non_neg_integer(), non_neg_integer()}}
          | {:error, {:invalid_argument, :input}}
          | {:error, {:invalid_options, option_error()}}
  @type encode_result ::
          {:ok, binary()}
          | {:error, {:invalid_argument, :record}}
          | {:error, {:invalid_record, domain_reason() | {:field, primitive_field()}}}
          | {:error, {:unsupported, unsupported_reason()}}

  @doc "Encodes a physical record; all primitive fields are checked before domain rules."
  @spec encode(term()) :: encode_result()
  def encode(
        %__MODULE__{
          format_version: version,
          record_type: type,
          flags: flags,
          payload_schema_version: schema,
          sequence: sequence,
          payload: payload
        } = record
      )
      when map_size(record) == 7 do
    with :ok <- validate_primitives(record),
         :ok <- validate_version(version),
         :ok <- validate_metadata(type, flags, schema, sequence, byte_size(payload)) do
      header =
        <<@magic, version, type, flags, schema, sequence::unsigned-big-64,
          byte_size(payload)::unsigned-big-32>>

      header_state = CRC32C.update(CRC32C.initial(), header)
      header_crc = CRC32C.finalize(header_state)
      record_crc = CRC32C.finalize(CRC32C.update(header_state, payload))

      {:ok,
       <<header::binary, header_crc::unsigned-big-32, payload::binary,
         record_crc::unsigned-big-32>>}
    else
      {:error, {:corrupt, reason}} -> {:error, {:invalid_record, reason}}
      error -> error
    end
  end

  def encode(_record), do: {:error, {:invalid_argument, :record}}

  @doc """
  Decodes one physical record, leaving all trailing bytes unchanged.

  The only option is `:max_decode_payload_bytes` (0..16_777_216, default
  16_777_216). This is a resource budget, not an insertion or format limit.
  A resource error permits retry with adequate resources at the same position.
  """
  @spec decode(term(), term()) :: decode_result()
  @spec decode(term()) :: decode_result()
  def decode(input, options \\ [])

  def decode(input, options) when is_binary(input) do
    with {:ok, limit} <- validate_options(options) do
      decode_prefix(input, limit)
    end
  end

  def decode(_input, _options), do: {:error, {:invalid_argument, :input}}

  defp validate_options(options) do
    if Keyword.keyword?(options) do
      keys = Keyword.keys(options)
      limit = Keyword.get(options, :max_decode_payload_bytes, @hard_payload_max)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          option_error(:duplicate_keys)

        Enum.any?(keys, &(&1 != :max_decode_payload_bytes)) ->
          option_error(:unknown_keys)

        not is_integer(limit) or limit < 0 or limit > @hard_payload_max ->
          option_error(:invalid_max_decode_payload_bytes)

        true ->
          {:ok, limit}
      end
    else
      option_error(:not_keyword)
    end
  end

  defp option_error(reason), do: {:error, {:invalid_options, reason}}

  defp decode_prefix(input, limit) do
    prefix_length = min(byte_size(input), 4)

    cond do
      binary_part(input, 0, prefix_length) != binary_part(@magic, 0, prefix_length) ->
        {:error, {:corrupt, :invalid_magic}}

      byte_size(input) < 5 ->
        {:incomplete, :header}

      true ->
        with :ok <- validate_version(:binary.at(input, 4)) do
          decode_header(input, limit)
        end
    end
  end

  defp validate_version(1), do: :ok
  defp validate_version(0), do: {:error, {:corrupt, {:invalid_format, 0}}}
  defp validate_version(version), do: {:error, {:unsupported, {:format, version}}}

  defp decode_header(input, _limit) when byte_size(input) < 24, do: {:incomplete, :header}

  defp decode_header(input, limit) do
    <<header::binary-size(20), stored_crc::unsigned-big-32, _::binary>> = input
    header_state = CRC32C.update(CRC32C.initial(), header)

    # Never use the advertised length (even to classify incompleteness) until
    # this fixed-size checksum succeeds. It also protects type/schema/sequence.
    if CRC32C.finalize(header_state) == stored_crc do
      <<@magic, 1, type, flags, schema, sequence::unsigned-big-64, n::unsigned-big-32>> = header

      with :ok <- validate_metadata(type, flags, schema, sequence, n) do
        decode_body(input, limit, type, schema, sequence, n, header_state)
      end
    else
      {:error, {:corrupt, :header_checksum}}
    end
  end

  defp validate_metadata(type, flags, schema, sequence, n) do
    cond do
      flags != 0 ->
        {:error, {:unsupported, {:flags, flags}}}

      type in [0, 255] ->
        {:error, {:corrupt, {:reserved_type, type}}}

      schema == 0 ->
        {:error, {:corrupt, {:invalid_schema, 0}}}

      sequence == 0 ->
        {:error, {:corrupt, {:invalid_sequence, 0}}}

      n > @hard_payload_max ->
        {:error, {:corrupt, {:payload_length_exceeds_format, n, @hard_payload_max}}}

      true ->
        :ok
    end
  end

  defp decode_body(input, limit, type, schema, sequence, n, header_state) do
    cond do
      n > limit ->
        {:error, {:resource_limit, n, limit}}

      byte_size(input) < 28 + n ->
        stage = if byte_size(input) < 24 + n, do: :payload, else: :checksum

        {:incomplete, stage,
         %{
           format_version: 1,
           record_type: type,
           flags: 0,
           payload_schema_version: schema,
           sequence: sequence,
           payload_length: n,
           record_bytes: 28 + n,
           available_bytes: byte_size(input),
           missing_bytes: 28 + n - byte_size(input)
         }}

      true ->
        <<_::binary-size(24), payload::binary-size(^n), stored_crc::unsigned-big-32,
          rest::binary>> = input

        if CRC32C.finalize(CRC32C.update(header_state, payload)) == stored_crc do
          {:ok,
           %__MODULE__{
             record_type: type,
             payload_schema_version: schema,
             sequence: sequence,
             payload: payload
           }, rest}
        else
          {:error, {:corrupt, :record_checksum}}
        end
    end
  end

  defp validate_primitives(record) do
    fields = [
      {:format_version, record.format_version, 255},
      {:record_type, record.record_type, 255},
      {:flags, record.flags, 255},
      {:payload_schema_version, record.payload_schema_version, 255},
      {:sequence, record.sequence, @uint64_max}
    ]

    case Enum.find(fields, fn {_field, value, max} ->
           not is_integer(value) or value < 0 or value > max
         end) do
      {field, _value, _max} -> {:error, {:invalid_record, {:field, field}}}
      nil when is_binary(record.payload) -> :ok
      nil -> {:error, {:invalid_record, {:field, :payload}}}
    end
  end
end
