defmodule Tay.Storage.RecordBoundaryTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Record
  alias Tay.Test.RecordHelpers, as: H
  alias Tay.Test.ReferenceCRC32C

  @hard 16_777_216
  @moduletag timeout: 180_000

  test "zero and one payload byte have distinct payload/checksum truncation boundaries" do
    for payload <- [<<>>, <<255>>] do
      record = H.record(payload: payload)
      bytes = H.frame(payload: payload)
      assert Record.encode(record) == {:ok, bytes}
      assert Record.decode(bytes) == {:ok, record, <<>>}

      for k <- 0..(byte_size(bytes) - 1) do
        assert Record.decode(binary_part(bytes, 0, k)) == H.incomplete(record, k)
      end
    end
  end

  test "16 MiB payload is legal and anchored to F10 plus an independent full record checksum" do
    payload = :binary.copy(<<0, 255, 84, 65, 89, 0, 127, 128>>, div(@hard, 8))

    record =
      H.record(
        record_type: 254,
        payload_schema_version: 255,
        sequence: 18_446_744_073_709_551_615,
        payload: payload
      )

    header = H.bytes("F10")
    logical_header = binary_part(header, 0, 20)
    crc = ReferenceCRC32C.checksum_chunks([logical_header, payload])
    independent_bytes = <<header::binary, payload::binary, crc::unsigned-big-32>>

    assert byte_size(independent_bytes) == 16_777_244
    # Neither decode expectation nor independent_bytes comes from Record.encode.
    assert Record.decode(independent_bytes) == {:ok, record, <<>>}
    assert Record.encode(record) == {:ok, independent_bytes}

    assert Record.decode(independent_bytes, max_decode_payload_bytes: @hard - 1) ==
             {:error, {:resource_limit, @hard, @hard - 1}}

    for k <- [
          0,
          4,
          5,
          23,
          24,
          25,
          24 + div(@hard, 2),
          24 + @hard - 1,
          24 + @hard,
          25 + @hard,
          26 + @hard,
          27 + @hard
        ] do
      assert Record.decode(binary_part(independent_bytes, 0, k)) == H.incomplete(record, k)
    end

    assert Record.decode(H.flip(independent_bytes, 24 + div(@hard, 2), 7)) ==
             {:error, {:corrupt, :record_checksum}}
  end

  test "one byte over the hard limit fails encoding before CRC and does not affect historical limits" do
    payload = :binary.copy(<<0>>, @hard + 1)

    assert Record.encode(H.record(payload: payload)) ==
             {:error, {:invalid_record, {:payload_length_exceeds_format, @hard + 1, @hard}}}

    assert Record.encode(H.record(payload: payload, sequence: 0)) ==
             {:error, {:invalid_record, {:invalid_sequence, 0}}}

    for id <- ["F11", "F12"] do
      assert Record.decode(H.bytes(id)) == H.expected(H.fixture(id))
    end
  end
end
