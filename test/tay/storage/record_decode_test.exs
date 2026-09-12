defmodule Tay.Storage.RecordDecodeTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Tay.Storage.Record
  alias Tay.Test.RecordHelpers, as: H
  alias Tay.Test.ReferenceCRC32C

  test "every strict prefix of every valid golden frame has the exact incomplete classification" do
    for fixture <- H.fixtures(), match?({:ok, _, _}, fixture.result) do
      {:ok, record, <<>>} = H.expected(fixture)
      bytes = H.bytes(fixture.id)

      for k <- 0..(byte_size(bytes) - 1) do
        prefix = binary_part(bytes, 0, k)
        assert Record.decode(prefix) == H.incomplete(record, k)

        assert Record.decode(prefix <> binary_part(bytes, k, byte_size(bytes) - k)) ==
                 {:ok, record, <<>>}
      end
    end
  end

  test "every observed magic byte is checked even before the entire prefix arrives" do
    bytes = H.bytes("F01")

    for offset <- 0..3, bit <- 0..7 do
      mutated = H.flip(bytes, offset, bit)

      assert Record.decode(binary_part(mutated, 0, offset + 1)) ==
               {:error, {:corrupt, :invalid_magic}}

      assert Record.decode(mutated) == {:error, {:corrupt, :invalid_magic}}
    end

    for bytes <- [<<0>>, "TAYS", "TAYF", "noise" <> H.bytes("F01")] do
      assert Record.decode(bytes) == {:error, {:corrupt, :invalid_magic}}
    end

    assert Record.decode(<<>>) == {:incomplete, :header}
    assert Record.decode("T") == {:incomplete, :header}
  end

  test "framing version is rejected at byte five without inspecting an assumed v1 tail" do
    for version <- 0..255, version != 1 do
      expected =
        if version == 0,
          do: {:error, {:corrupt, {:invalid_format, 0}}},
          else: {:error, {:unsupported, {:format, version}}}

      assert Record.decode(<<"TAY", 0, version>>) == expected

      assert Record.decode(<<"TAY", 0, version, 0, 255, 0>> <> :binary.copy(<<255>>, 80)) ==
               expected
    end
  end

  test "partial v1 headers never classify unchecked metadata" do
    bytes =
      H.frame(
        record_type: 0,
        flags: 255,
        payload_schema_version: 0,
        sequence: 0,
        payload_length: 0xFFFFFFFF
      )

    for k <- 5..23 do
      assert Record.decode(binary_part(bytes, 0, k), max_decode_payload_bytes: 0) ==
               {:incomplete, :header}
    end
  end

  test "every single-bit mutation in all valid fixture bytes has the precise error precedence" do
    for id <- ["F01", "F02", "F03", "F07", "F09", "F18"] do
      bytes = H.bytes(id)

      for offset <- 0..(byte_size(bytes) - 1), bit <- 0..7 do
        expected =
          cond do
            offset < 4 -> {:error, {:corrupt, :invalid_magic}}
            offset == 4 and bit == 0 -> {:error, {:corrupt, {:invalid_format, 0}}}
            offset == 4 -> {:error, {:unsupported, {:format, bxor(1, 1 <<< bit)}}}
            offset < 24 -> {:error, {:corrupt, :header_checksum}}
            true -> {:error, {:corrupt, :record_checksum}}
          end

        assert Record.decode(H.flip(bytes, offset, bit)) == expected
      end
    end
  end

  test "all header fields remain bound by record CRC after only header CRC is repaired" do
    original = H.bytes("F02")
    <<_::binary-size(20), _::32, body::binary>> = original

    for {offset, bit} <- [{5, 1}, {7, 1}, {8, 0}, {15, 0}] do
      header = original |> H.flip(offset, bit) |> binary_part(0, 20)
      bytes = <<header::binary, ReferenceCRC32C.checksum(header)::unsigned-big-32, body::binary>>
      assert Record.decode(bytes) == {:error, {:corrupt, :record_checksum}}
    end
  end

  test "fixed header checksum precedes structural values, length, budget, and missing body" do
    bad =
      H.frame(
        record_type: 0,
        flags: 1,
        payload_schema_version: 0,
        sequence: 0,
        payload_length: 0xFFFFFFFF
      )

    bad = H.flip(bad, 20, 0)

    assert Record.decode(binary_part(bad, 0, 24), max_decode_payload_bytes: 0) ==
             {:error, {:corrupt, :header_checksum}}
  end

  test "checksummed structural domains win in flags/type/schema/sequence/hard-limit order" do
    cases = [
      {[
         flags: 1,
         record_type: 0,
         payload_schema_version: 0,
         sequence: 0,
         payload_length: 0xFFFFFFFF
       ], {:unsupported, {:flags, 1}}},
      {[record_type: 0, payload_schema_version: 0, sequence: 0, payload_length: 0xFFFFFFFF],
       {:corrupt, {:reserved_type, 0}}},
      {[record_type: 255, payload_schema_version: 0], {:corrupt, {:reserved_type, 255}}},
      {[payload_schema_version: 0, sequence: 0, payload_length: 0xFFFFFFFF],
       {:corrupt, {:invalid_schema, 0}}},
      {[sequence: 0, payload_length: 0xFFFFFFFF], {:corrupt, {:invalid_sequence, 0}}},
      {[payload_length: 16_777_217],
       {:corrupt, {:payload_length_exceeds_format, 16_777_217, 16_777_216}}},
      {[payload_length: 0xFFFFFFFF],
       {:corrupt, {:payload_length_exceeds_format, 0xFFFFFFFF, 16_777_216}}}
    ]

    for {fields, error} <- cases do
      header = fields |> H.frame() |> binary_part(0, 24)
      assert Record.decode(header, max_decode_payload_bytes: 0) == {:error, error}
    end

    for flags <- 1..255 do
      assert Record.decode(H.frame(flags: flags)) == {:error, {:unsupported, {:flags, flags}}}
    end
  end

  test "A/B/C length corruption preserves the entire B/C remainder and is never incomplete" do
    a = H.bytes("F01")
    bad_b = H.flip(H.bytes("F02"), 19, 6)
    c = H.bytes("F18")
    expected_rest = bad_b <> c
    assert byte_size(expected_rest) == 65
    assert {:ok, %{sequence: 1}, ^expected_rest} = Record.decode(a <> expected_rest)
    assert Record.decode(expected_rest) == {:error, {:corrupt, :header_checksum}}

    assert Record.decode(expected_rest, max_decode_payload_bytes: 0) ==
             {:error, {:corrupt, :header_checksum}}
  end

  test "single-record decode preserves every trailing byte, including corrupt/unsupported/incomplete data" do
    a = H.bytes("F01")

    remainders = [
      H.bytes("F02"),
      H.bytes("F05"),
      H.bytes("F06"),
      H.bytes("F08"),
      H.bytes("F07"),
      H.bytes("F09"),
      <<0>>,
      "T",
      <<>>,
      :binary.copy(<<255>>, 100)
    ]

    for rest <- remainders do
      assert {:ok, %{sequence: 1}, ^rest} = Record.decode(a <> rest)
    end

    assert {:ok, b, <<>>} = Record.decode(H.bytes("F02"))
    assert b.payload == <<0, 255, 84, 65, 89, 0, 127, 128, 10>>
    refute String.valid?(b.payload)
  end

  test "assignable unknown semantics succeed without hiding corruption in the next frame" do
    b = H.frame(record_type: 47, payload_schema_version: 3, sequence: 2)
    c = H.bytes("F05")
    assert {:ok, %{record_type: 47, payload_schema_version: 3}, ^c} = Record.decode(b <> c)
    assert Record.decode(c) == {:error, {:corrupt, :record_checksum}}
  end

  test "duplicate, gapped, reordered, and maximum sequences remain individually physically valid" do
    for sequences <- [[1, 1, 2], [1, 3], [3, 2, 1], [18_446_744_073_709_551_615, 1]] do
      input = sequences |> Enum.map(&H.frame(sequence: &1)) |> IO.iodata_to_binary()

      rest =
        Enum.reduce(sequences, input, fn sequence, remaining ->
          assert {:ok, %{sequence: ^sequence}, rest} = Record.decode(remaining)
          rest
        end)

      assert rest == <<>>
    end
  end

  test "resource budget is checked after hard limit but before any missing body or checksum" do
    bytes = H.bytes("F02")

    for k <- 24..byte_size(bytes) do
      assert Record.decode(binary_part(bytes, 0, k), max_decode_payload_bytes: 8) ==
               {:error, {:resource_limit, 9, 8}}
    end

    assert {:ok, _, <<>>} = Record.decode(bytes, max_decode_payload_bytes: 9)
    assert {:ok, _, ^bytes} = Record.decode(H.bytes("F01") <> bytes, max_decode_payload_bytes: 0)

    assert Record.decode(H.bytes("F10"), max_decode_payload_bytes: 0) ==
             {:error, {:resource_limit, 16_777_216, 0}}

    assert Record.decode(H.bytes("F05"), max_decode_payload_bytes: 8) ==
             {:error, {:resource_limit, 9, 8}}
  end

  test "unknown numeric semantics preserve physical incomplete/checksum/resource classifications" do
    record = H.record(record_type: 47, payload_schema_version: 3, payload: <<255, 0, 84>>)
    bytes = H.frame(record_type: 47, payload_schema_version: 3, payload: record.payload)

    for k <- 24..30 do
      assert Record.decode(binary_part(bytes, 0, k)) == H.incomplete(record, k)

      assert Record.decode(binary_part(bytes, 0, k), max_decode_payload_bytes: 2) ==
               {:error, {:resource_limit, 3, 2}}
    end

    assert Record.decode(H.flip(bytes, 24, 0)) == {:error, {:corrupt, :record_checksum}}
  end

  test "argument validation precedes options and all byte classification" do
    for value <- [nil, false, 42, 1.0, :input, [], ~c"TAY", [<<84>>], %{}, <<1::1>>, [1 | 2]] do
      assert Record.decode(value) == {:error, {:invalid_argument, :input}}
      assert Record.decode(value, :invalid) == {:error, {:invalid_argument, :input}}
    end

    for options <- [
          nil,
          :invalid,
          %{},
          "",
          [:key],
          [{"key", 1}],
          [max_decode_payload_bytes: 1] ++ [false],
          [{:key, 1} | 2]
        ] do
      assert Record.decode(<<0>>, options) == {:error, {:invalid_options, :not_keyword}}
    end

    assert Record.decode(<<>>, max_decode_payload_bytes: 1, max_decode_payload_bytes: 2) ==
             {:error, {:invalid_options, :duplicate_keys}}

    assert Record.decode(<<0>>, typo: 1, typo: 2, max_decode_payload_bytes: -1) ==
             {:error, {:invalid_options, :duplicate_keys}}

    for key <- [:typo, :supported_schemas, :insertion_limit, :repair, :skip_unknown] do
      assert Record.decode(<<0>>, [{key, %{}}, {:max_decode_payload_bytes, -1}]) ==
               {:error, {:invalid_options, :unknown_keys}}
    end

    for limit <- [-1, 16_777_217, 1.0, false, nil, "9", [], %{}] do
      assert Record.decode(<<0>>, max_decode_payload_bytes: limit) ==
               {:error, {:invalid_options, :invalid_max_decode_payload_bytes}}
    end
  end
end
