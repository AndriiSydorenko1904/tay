defmodule Tay.Storage.RecordEncodeTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Record
  alias Tay.Test.RecordHelpers, as: H

  for fixture <- H.fixtures(), match?({:ok, _, _}, fixture.result) do
    @fixture fixture
    test "encodes #{fixture.id}'s logical fields to permanent bytes independently of decoding" do
      {:ok, fields, <<>>} = @fixture.result
      assert Record.encode(struct!(Record, fields)) == {:ok, H.bytes(@fixture.id)}
    end
  end

  test "struct contains exactly six fields, defaults only framing version and flags" do
    record = %Record{record_type: 47, payload_schema_version: 3, sequence: 1, payload: <<>>}

    assert Map.from_struct(record) == %{
             format_version: 1,
             flags: 0,
             record_type: 47,
             payload_schema_version: 3,
             sequence: 1,
             payload: <<>>
           }

    for key <- [:record_type, :payload_schema_version, :sequence, :payload] do
      fields = record |> Map.from_struct() |> Map.delete(key)
      assert_raise ArgumentError, fn -> struct!(Record, fields) end
    end

    refute function_exported?(Record, :encode, 2)
  end

  test "rejects non-records and malformed struct-shaped maps without raising" do
    valid = H.record()

    malformed =
      [
        nil,
        false,
        1,
        1.2,
        <<>>,
        <<1::1>>,
        [],
        %{},
        Map.from_struct(valid),
        %{__struct__: Record},
        Map.put(valid, :extra, true)
      ] ++
        for(key <- Map.keys(valid), do: Map.delete(valid, key))

    # Same map size as a record is insufficient if a declared key is missing.
    malformed = [valid |> Map.delete(:payload) |> Map.put(:extra, <<>>) | malformed]

    for value <- malformed do
      assert Record.encode(value) == {:error, {:invalid_argument, :record}}
    end
  end

  test "primitive types and widths are checked before every physical domain rule" do
    fields = [:format_version, :record_type, :flags, :payload_schema_version, :sequence]

    for field <- fields do
      max = if field == :sequence, do: 18_446_744_073_709_551_615, else: 255

      for value <- [-1, max + 1, 1.0, nil, :value, "1", [], false] do
        assert Record.encode(Map.put(H.record(), field, value)) ==
                 {:error, {:invalid_record, {:field, field}}}
      end
    end

    for value <- [nil, false, :payload, 0, 1.0, [], [<<1>>], ~c"bytes", %{}, <<1::1>>] do
      assert Record.encode(H.record(payload: value)) ==
               {:error, {:invalid_record, {:field, :payload}}}
    end

    assert Record.encode(H.record(format_version: 2, payload: nil)) ==
             {:error, {:invalid_record, {:field, :payload}}}

    assert Record.encode(H.record(record_type: 0, sequence: -1)) ==
             {:error, {:invalid_record, {:field, :sequence}}}

    ordered = fields ++ [:payload]

    for {field, index} <- Enum.with_index(ordered) do
      values = for later <- Enum.drop(ordered, index), do: {later, nil}
      assert Record.encode(H.record(values)) == {:error, {:invalid_record, {:field, field}}}
    end
  end

  test "encoder domain errors and precedence match the RFC without wrapping integers" do
    cases = [
      {[format_version: 0, flags: 1], {:invalid_record, {:invalid_format, 0}}},
      {[format_version: 2, flags: 1], {:unsupported, {:format, 2}}},
      {[flags: 1, record_type: 0], {:unsupported, {:flags, 1}}},
      {[record_type: 0, payload_schema_version: 0], {:invalid_record, {:reserved_type, 0}}},
      {[record_type: 255, sequence: 0], {:invalid_record, {:reserved_type, 255}}},
      {[payload_schema_version: 0, sequence: 0], {:invalid_record, {:invalid_schema, 0}}},
      {[sequence: 0], {:invalid_record, {:invalid_sequence, 0}}}
    ]

    for {fields, error} <- cases, do: assert(Record.encode(H.record(fields)) == {:error, error})

    for version <- 2..255 do
      assert Record.encode(H.record(format_version: version)) ==
               {:error, {:unsupported, {:format, version}}}
    end

    for flags <- 1..255 do
      assert Record.encode(H.record(flags: flags)) == {:error, {:unsupported, {:flags, flags}}}
    end
  end

  test "all 64,770 assignable type/schema combinations are physically encodable and decodable" do
    for type <- 1..254, schema <- 1..255 do
      record = H.record(record_type: type, payload_schema_version: schema, payload: <<0, 255>>)
      assert {:ok, bytes} = Record.encode(record)
      assert Record.decode(bytes) == {:ok, record, <<>>}
    end
  end

  test "encodes exact big-endian layout and unmodified opaque bytes" do
    sequence = 0x0102030405060708
    payload = :binary.copy(<<255, 0>>, 129)

    record =
      H.record(record_type: 47, payload_schema_version: 3, sequence: sequence, payload: payload)

    assert {:ok, bytes} = Record.encode(record)

    assert <<"TAY", 0, 1, 47, 0, 3, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 1, 2,
             _header_crc::unsigned-big-32, ^payload::binary-size(258),
             _record_crc::unsigned-big-32>> = bytes

    assert bytes ==
             H.frame(
               record_type: 47,
               payload_schema_version: 3,
               sequence: sequence,
               payload: payload
             )
  end
end
