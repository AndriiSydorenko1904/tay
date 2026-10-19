defmodule Tay.Storage.RecordPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Storage.{CRC32C, Record}
  alias Tay.Test.RecordHelpers, as: H
  alias Tay.Test.ReferenceCRC32C

  @max_sequence 18_446_744_073_709_551_615

  property "legal records round-trip with exact opaque bytes and arbitrary untouched remainder" do
    check all(
            record <- records(binary(max_length: 2048)),
            rest <- binary(max_length: 128),
            max_runs: 300
          ) do
      assert {:ok, bytes} = Record.encode(record)
      assert Record.decode(bytes <> rest) == {:ok, record, rest}
      assert bytes == H.frame(Map.to_list(Map.from_struct(record)))
      assert byte_size(bytes) == 28 + byte_size(record.payload)
    end
  end

  property "every strict prefix of a small record is precisely incomplete, never another complete record" do
    check all(record <- records(binary(max_length: 128)), max_runs: 250) do
      assert {:ok, bytes} = Record.encode(record)

      for k <- 0..(byte_size(bytes) - 1) do
        assert Record.decode(binary_part(bytes, 0, k)) == H.incomplete(record, k)
      end
    end
  end

  property "larger records preserve safety at sampled interior and every framing boundary" do
    check all(
            record <- records(binary(min_length: 4096, max_length: 65_536)),
            k <- integer(0..(27 + byte_size(record.payload))),
            max_runs: 40
          ) do
      assert {:ok, bytes} = Record.encode(record)
      n = byte_size(record.payload)

      boundaries =
        Enum.to_list(0..24) ++ [25, k, 24 + div(n, 2), 23 + n, 24 + n, 25 + n, 26 + n, 27 + n]

      for boundary <- boundaries do
        assert Record.decode(binary_part(bytes, 0, boundary)) == H.incomplete(record, boundary)
      end
    end
  end

  property "arbitrary binary and checksummed adversarial inputs stay in the exact physical result union" do
    check all(
            bytes <- one_of([binary(max_length: 2048), prefixed_bytes(), adversarial_frames()]),
            limit <- one_of([constant(16_777_216), integer(0..2048)]),
            max_runs: 1000
          ) do
      result = Record.decode(bytes, max_decode_payload_bytes: limit)
      assert_physical_result(result, bytes, limit)
    end
  end

  property "single-bit length mutations cannot swallow subsequent valid records" do
    check all(
            record <- records(binary(max_length: 256)),
            offset <- integer(16..19),
            bit <- integer(0..7),
            max_runs: 250
          ) do
      assert {:ok, bytes} = Record.encode(record)
      bad = H.flip(bytes, offset, bit)
      assert Record.decode(bad <> H.bytes("F18")) == {:error, {:corrupt, :header_checksum}}
    end
  end

  property "arbitrary chunk boundaries preserve incremental CRC and independent coverage" do
    check all(
            bytes <- binary(max_length: 4096),
            split <- integer(0..byte_size(bytes)),
            max_runs: 250
          ) do
      <<left::binary-size(^split), right::binary>> = bytes

      actual =
        CRC32C.initial() |> CRC32C.update(left) |> CRC32C.update(right) |> CRC32C.finalize()

      assert actual == CRC32C.checksum(bytes)
      assert actual == ReferenceCRC32C.checksum(bytes)
    end
  end

  property "resource errors never become incompleteness and retry preserves the same bytes" do
    check all(
            record <- records(binary(min_length: 1, max_length: 1024)),
            limit <- integer(0..(byte_size(record.payload) - 1)),
            k <- integer(24..(28 + byte_size(record.payload))),
            max_runs: 250
          ) do
      assert {:ok, bytes} = Record.encode(record)

      assert Record.decode(binary_part(bytes, 0, k), max_decode_payload_bytes: limit) ==
               {:error, {:resource_limit, byte_size(record.payload), limit}}

      assert Record.decode(bytes) == {:ok, record, <<>>}
    end
  end

  defp records(payload_generator) do
    gen all(
          type <- integer(1..254),
          schema <- integer(1..255),
          sequence <- one_of([constant(1), constant(@max_sequence), integer(1..@max_sequence)]),
          payload <- payload_generator
        ) do
      H.record(
        record_type: type,
        payload_schema_version: schema,
        sequence: sequence,
        payload: payload
      )
    end
  end

  defp prefixed_bytes do
    gen all(
          prefix <- member_of(["T", "TA", "TAY", <<"TAY", 0>>, <<"TAY", 0, 1>>]),
          rest <- binary(max_length: 512)
        ) do
      prefix <> rest
    end
  end

  defp adversarial_frames do
    gen all(
          version <- one_of([constant(1), integer(0..255)]),
          type <- integer(0..255),
          flags <- one_of([constant(0), integer(0..255)]),
          schema <- integer(0..255),
          sequence <- integer(0..@max_sequence),
          payload <- binary(max_length: 256),
          n <-
            one_of([
              constant(byte_size(payload)),
              integer(0..512),
              constant(16_777_217),
              constant(0xFFFFFFFF)
            ]),
          keep <- integer(0..(28 + byte_size(payload)))
        ) do
      bytes =
        H.frame(
          format_version: version,
          record_type: type,
          flags: flags,
          payload_schema_version: schema,
          sequence: sequence,
          payload: payload,
          payload_length: n
        )

      binary_part(bytes, 0, keep)
    end
  end

  defp assert_physical_result({:ok, record, rest}, bytes, limit) do
    assert record.record_type in 1..254
    assert record.payload_schema_version in 1..255
    assert record.sequence in 1..@max_sequence
    assert record.format_version == 1 and record.flags == 0
    assert byte_size(record.payload) <= min(limit, 16_777_216)
    assert H.frame(Map.to_list(Map.from_struct(record))) <> rest == bytes
  end

  defp assert_physical_result({:incomplete, :header}, bytes, _limit),
    do: assert(byte_size(bytes) < 24)

  defp assert_physical_result({:incomplete, stage, metadata}, bytes, limit)
       when stage in [:payload, :checksum] do
    assert Map.keys(metadata) |> Enum.sort() ==
             Enum.sort([
               :format_version,
               :record_type,
               :flags,
               :payload_schema_version,
               :sequence,
               :payload_length,
               :record_bytes,
               :available_bytes,
               :missing_bytes
             ])

    assert metadata.record_type in 1..254 and metadata.payload_schema_version in 1..255
    assert metadata.sequence in 1..@max_sequence
    assert metadata.format_version == 1 and metadata.flags == 0
    assert metadata.payload_length in 0..16_777_216
    assert metadata.payload_length <= limit
    assert metadata.available_bytes == byte_size(bytes)
    assert metadata.record_bytes == 28 + metadata.payload_length
    assert metadata.missing_bytes == metadata.record_bytes - byte_size(bytes)
    assert metadata.missing_bytes > 0

    assert stage ==
             if(byte_size(bytes) < 24 + metadata.payload_length, do: :payload, else: :checksum)
  end

  defp assert_physical_result({:error, {:corrupt, reason}}, _bytes, _limit) do
    case reason do
      atom when atom in [:invalid_magic, :header_checksum, :record_checksum] ->
        :ok

      {:invalid_format, 0} ->
        :ok

      {:reserved_type, type} when type in [0, 255] ->
        :ok

      {:invalid_schema, 0} ->
        :ok

      {:invalid_sequence, 0} ->
        :ok

      {:payload_length_exceeds_format, n, 16_777_216} when n > 16_777_216 and n <= 0xFFFFFFFF ->
        :ok

      other ->
        flunk("out-of-contract corruption result: #{inspect(other)}")
    end
  end

  defp assert_physical_result({:error, {:unsupported, {:format, version}}}, _bytes, _limit),
    do: assert(version in 2..255)

  defp assert_physical_result({:error, {:unsupported, {:flags, flags}}}, _bytes, _limit),
    do: assert(flags in 1..255)

  defp assert_physical_result({:error, {:resource_limit, n, l}}, _bytes, limit) do
    assert l == limit
    assert n > l and n <= 16_777_216
  end

  defp assert_physical_result(other, _bytes, _limit),
    do: flunk("out-of-contract result: #{inspect(other)}")
end
