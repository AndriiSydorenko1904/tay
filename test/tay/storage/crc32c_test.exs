defmodule Tay.Storage.CRC32CTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tay.Storage.CRC32C
  alias Tay.Test.ReferenceCRC32C
  alias Tay.Storage.CRC32C.{Native, Reference}

  @vectors [
    {"empty", <<>>, 0x00000000},
    {"ASCII check", "123456789", 0xE3069283},
    {"32 zero bytes", :binary.copy(<<0>>, 32), 0x8A9136AA},
    {"32 FF bytes", :binary.copy(<<255>>, 32), 0x62A8AB43},
    {"ascending bytes", :binary.list_to_bin(Enum.to_list(0..31)), 0x46DD794E},
    {"descending bytes", :binary.list_to_bin(Enum.to_list(31..0//-1)), 0x113FDB5C}
  ]

  for {name, bytes, expected} <- @vectors do
    test "standard CRC32C vector: #{name}" do
      assert CRC32C.checksum(unquote(bytes)) == unquote(expected)
      assert ReferenceCRC32C.checksum(unquote(bytes)) == unquote(expected)
    end
  end

  test "incremental raw registers match every split of all standard vectors" do
    for {_name, bytes, expected} <- @vectors, split <- 0..byte_size(bytes) do
      <<left::binary-size(^split), right::binary>> = bytes

      actual =
        CRC32C.initial()
        |> CRC32C.update(<<>>)
        |> CRC32C.update(left)
        |> CRC32C.update(<<>>)
        |> CRC32C.update(right)
        |> CRC32C.finalize()

      assert actual == expected
    end
  end

  test "CRC integers are stored big-endian, not reflected or complemented again" do
    assert <<CRC32C.checksum("123456789")::unsigned-big-32>> == <<0xE3, 0x06, 0x92, 0x83>>
    refute CRC32C.checksum("123456789") == :erlang.crc32("123456789")
  end

  test "native implementation is loaded and agrees with the independent oracle across chunk boundaries" do
    assert Native.available?()
    bytes = for(i <- 0..4096, into: <<>>, do: <<rem(i * 131 + 17, 256)>>)
    expected = ReferenceCRC32C.checksum(bytes)

    assert CRC32C.checksum(bytes) == expected

    for chunk_size <- [1, 7, 8, 9, 63, 64, 255, 1024] do
      actual =
        bytes
        |> chunk(chunk_size)
        |> Enum.reduce(CRC32C.initial(), &CRC32C.update(&2, &1))
        |> CRC32C.finalize()

      assert actual == expected
    end
  end

  property "native updates preserve arbitrary raw registers and chunk boundaries" do
    check all(
            bytes <- binary(max_length: 16_384),
            register <- integer(0..0xFFFFFFFF),
            split <- integer(0..byte_size(bytes)),
            max_runs: 200
          ) do
      <<left::binary-size(^split), right::binary>> = bytes
      expected = Reference.update(register, bytes)
      assert CRC32C.update(register, bytes) == expected
      assert register |> CRC32C.update(left) |> CRC32C.update(right) == expected
    end
  end

  property "one-call record checksums match the independent oracle and incremental updates" do
    check all(
            header <- binary(max_length: 128),
            payload <- binary(max_length: 16_384),
            max_runs: 200
          ) do
      header_state = CRC32C.update(CRC32C.initial(), header)

      expected =
        {ReferenceCRC32C.checksum(header), ReferenceCRC32C.checksum_chunks([header, payload])}

      assert CRC32C.record_checksums(header, payload) == expected

      assert {CRC32C.finalize(header_state),
              CRC32C.finalize(CRC32C.update(header_state, payload))} == expected
    end
  end

  test "record checksums handle empty inputs, slicing tails and both scheduler thresholds" do
    sizes = for h <- 0..17, p <- 0..17, do: {h, p}

    sizes =
      sizes ++
        [{20, 4095}, {20, 4096}, {20, 4097}, {0, 4097}, {4097, 0}, {4096, 4096}, {4096, 4097}]

    source = :binary.copy(<<0, 127, 128, 255>>, 2048)

    for {header_size, payload_size} <- sizes do
      header = binary_part(source, 1, header_size)
      payload = binary_part(source, 3, payload_size)
      wrapped = <<5::3, payload::binary, 0::5>>
      <<_::3, unaligned_payload::binary-size(^payload_size), _::5>> = wrapped

      expected =
        {ReferenceCRC32C.checksum(header), ReferenceCRC32C.checksum_chunks([header, payload])}

      assert CRC32C.record_checksums(header, payload) == expected
      assert CRC32C.record_checksums(header, unaligned_payload) == expected

      assert CRC32C.record_checksums(unaligned_payload, header) ==
               {ReferenceCRC32C.checksum(payload),
                ReferenceCRC32C.checksum_chunks([payload, header])}
    end
  end

  test "slicing tails, scheduler threshold and unaligned sub-binaries match the reference" do
    source = :binary.copy(:binary.list_to_bin(Enum.to_list(0..255)), 33)

    for size <- Enum.to_list(0..17) ++ Enum.to_list(4089..4104), offset <- 0..7 do
      bytes = binary_part(source, offset, size)
      # Also exercise binaries whose first byte starts inside a bitstring.
      wrapped = <<5::3, bytes::binary, 0::5>>
      <<_::3, unaligned::binary-size(^size), _::5>> = wrapped

      for register <- [0, 1, 0x80000000, 0xFFFFFFFF] do
        expected = Reference.update(register, bytes)
        assert CRC32C.update(register, bytes) == expected
        assert CRC32C.update(register, unaligned) == expected
      end
    end
  end

  test "maximum record payload and concurrent dirty updates match the independent oracle" do
    bytes = :binary.copy(<<0, 127, 128, 255>>, div(16_777_216, 4))
    expected = ReferenceCRC32C.checksum(bytes)
    assert CRC32C.checksum(bytes) == expected
    assert Reference.checksum(bytes) == expected
    header = "record header"

    record_expected =
      {ReferenceCRC32C.checksum(header), ReferenceCRC32C.checksum_chunks([header, bytes])}

    assert CRC32C.record_checksums(header, bytes) == record_expected

    1..16
    |> Task.async_stream(
      fn _ ->
        {CRC32C.checksum(bytes), CRC32C.record_checksums(header, bytes)}
      end,
      max_concurrency: 8
    )
    |> Enum.each(fn result -> assert result == {:ok, {expected, record_expected}} end)
  end

  test "public guards and native boundary reject invalid inputs" do
    for register <- [-1, 0x100000000, 1.0, :bad], bytes <- [<<>>, "123"] do
      assert_raise FunctionClauseError, fn -> CRC32C.update(register, bytes) end
      assert_raise ArgumentError, fn -> Native.update(register, bytes) end
    end

    for bytes <- [[], [1, 2], <<1::1>>, nil] do
      assert_raise FunctionClauseError, fn -> CRC32C.update(0, bytes) end
      assert_raise ArgumentError, fn -> Native.update(0, bytes) end
      assert_raise FunctionClauseError, fn -> CRC32C.record_checksums(bytes, <<>>) end
      assert_raise FunctionClauseError, fn -> CRC32C.record_checksums(<<>>, bytes) end
      assert_raise ArgumentError, fn -> Native.record_checksums(bytes, <<>>) end
      assert_raise ArgumentError, fn -> Native.record_checksums(<<>>, bytes) end
    end
  end

  defp chunk(<<>>, _size), do: []

  defp chunk(bytes, size) do
    take = min(byte_size(bytes), size)
    <<head::binary-size(^take), rest::binary>> = bytes
    [head | chunk(rest, size)]
  end
end
