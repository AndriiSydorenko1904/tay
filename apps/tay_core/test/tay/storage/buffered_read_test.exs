defmodule Tay.Storage.BufferedReadTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.BufferedRead

  test "small sequential reads share read-ahead and a large read is direct" do
    bytes = :binary.copy(<<0, 1, 2, 3>>, 600_000)
    owner = self()

    source = fn offset, length ->
      send(owner, {:read, offset, length})
      {:ok, binary_part(bytes, offset, length)}
    end

    assert :ok =
             BufferedRead.with_reader(source, byte_size(bytes), fn read ->
               assert {:ok, <<0, 1, 2, 3>>} = read.(0, 4)
               assert {:ok, <<0, 1, 2, 3>>} = read.(100, 4)
               assert {:ok, direct} = read.(200_000, 1_200_000)
               assert byte_size(direct) == 1_200_000
               :ok
             end)

    assert_received {:read, 0, 1_048_576}
    assert_received {:read, 200_000, 1_200_000}
    refute_received {:read, 100, _}
    refute_received {:read, _, _}
  end

  test "reports configured short-read and range errors" do
    source = fn _offset, _length -> {:ok, <<1>>} end

    assert :ok =
             BufferedRead.with_reader(
               source,
               10,
               fn read ->
                 assert {:error, :truncated} = read.(0, 2)
                 assert {:error, :outside} = read.(9, 2)
                 :ok
               end,
               chunk_bytes: 2,
               short_read: :truncated,
               invalid_range: :outside
             )
  end
end
