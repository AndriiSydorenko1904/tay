defmodule Tay.Storage.CRC32CTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.CRC32C
  alias Tay.Test.ReferenceCRC32C

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

  test "table implementation agrees with the independent oracle across chunk boundaries" do
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

  defp chunk(<<>>, _size), do: []

  defp chunk(bytes, size) do
    take = min(byte_size(bytes), size)
    <<head::binary-size(^take), rest::binary>> = bytes
    [head | chunk(rest, size)]
  end
end
