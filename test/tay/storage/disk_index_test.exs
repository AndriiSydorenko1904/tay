defmodule Tay.Storage.DiskIndexTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.DiskIndex

  setup do
    path = Tay.Test.NativeHelpers.path() <> ".index"
    {:ok, file} = :file.open(String.to_charlist(path), [:raw, :binary, :read, :write])
    on_exit(fn -> File.rm(path) end)
    %{index_file: file, path: path}
  end

  defp key(n), do: <<n::64>>
  defp write(file), do: fn offset, bytes -> :file.pwrite(file, offset, bytes) end
  defp read(file), do: fn offset, length -> :file.pread(file, offset, length) end

  test "reopened multilevel index reads only a search path", %{index_file: file, path: path} do
    entries = Stream.map(1..9_000, &{key(&1), %{"segment" => &1, "offset" => &1 * 128}})
    assert {:ok, root, bytes} = DiskIndex.build(entries, write(file))
    assert root.count == 9_000
    assert root.height == 2
    assert {:ok, root_bytes} = DiskIndex.encode_root(root)
    assert {:ok, ^root} = DiskIndex.decode_root(root_bytes)
    assert :ok = :file.sync(file)
    assert :ok = :file.close(file)
    {:ok, reopened} = :file.open(String.to_charlist(path), [:raw, :binary, :read])
    parent = self()

    counted = fn offset, size ->
      send(parent, {:read, size})
      :file.pread(reopened, offset, size)
    end

    assert {:ok, %{"segment" => 8_999, "offset" => offset}} =
             DiskIndex.fetch(counted, root, key(8_999))

    assert offset == 8_999 * 128

    sizes =
      for _ <- 1..3 do
        assert_receive {:read, size}
        size
      end

    refute_receive {:read, _}
    assert Enum.sum(sizes) < div(bytes, 10)
    assert :not_found = DiskIndex.fetch(counted, root, key(9_001))
    refute_receive {:read, _}

    for n <- [1, 64, 65, 4_096, 4_097, 9_000] do
      assert {:ok, %{"segment" => ^n}} = DiskIndex.fetch(read(reopened), root, key(n))
    end

    assert :ok = :file.close(reopened)
  end

  test "pagination crosses leaves and tree branches without skipping or duplicating keys", %{
    index_file: file
  } do
    expected = Enum.map(1..4_300, &{key(&1 * 2), &1})
    assert {:ok, root, _} = DiskIndex.build(expected, write(file), 17)
    assert {:ok, first} = DiskIndex.page(read(file), root, nil, 70)
    assert first == Enum.take(expected, 70)
    assert {:ok, crossing} = DiskIndex.page(read(file), root, key(8_170), 40)
    assert crossing == Enum.slice(expected, 4_085, 40)
    assert {:ok, []} = DiskIndex.page(read(file), root, key(8_600), 5)
    assert :not_found = DiskIndex.fetch(read(file), root, key(135))
    assert :ok = :file.close(file)
  end

  test "empty and single-page indexes preserve nil and binary values", %{index_file: file} do
    never = fn _, _ -> flunk("empty index attempted I/O") end
    assert {:ok, nil, 0} = DiskIndex.build([], never)
    assert {:ok, encoded} = DiskIndex.encode_root(nil)
    assert {:ok, nil} = DiskIndex.decode_root(encoded)
    assert :not_found = DiskIndex.fetch(never, nil, <<>>)
    assert {:ok, []} = DiskIndex.page(never, nil)

    assert {:ok, root, _} =
             DiskIndex.build([{<<>>, nil}, {<<255>>, {:bytes, <<0, 255>>}}], write(file))

    assert {:ok, nil} = DiskIndex.fetch(read(file), root, <<>>)
    assert {:ok, {:bytes, <<0, 255>>}} = DiskIndex.fetch(read(file), root, <<255>>)
    assert :ok = :file.close(file)
  end

  test "corrupt and truncated pages fail instead of returning missing data", %{index_file: file} do
    assert {:ok, root, _} = DiskIndex.build(Enum.map(1..65, &{key(&1), &1}), write(file))
    assert {:ok, <<first, rest::binary>>} = :file.pread(file, 0, 8)
    assert :ok = :file.pwrite(file, 0, <<Bitwise.bxor(first, 1), rest::binary>>)
    assert {:error, :index_digest} = DiskIndex.fetch(read(file), root, key(1))
    assert {:ok, 65} = DiskIndex.fetch(read(file), root, key(65))
    short = fn offset, size -> :file.pread(file, offset, size - 1) end
    assert {:error, :index_short_read} = DiskIndex.fetch(short, root, key(65))
    assert {:error, :index_short_read} = DiskIndex.fetch(fn _, _ -> :eof end, root, key(65))
    assert {:error, :index_reference} = DiskIndex.fetch(read(file), %{root | bytes: -1}, key(1))
    assert :ok = :file.close(file)
  end

  test "authenticated but malformed nodes cannot redirect traversal", %{index_file: file} do
    assert {:ok, root, _} = DiskIndex.build(Enum.map(1..65, &{key(&1), &1}), write(file))
    assert {:ok, raw} = :file.pread(file, root.offset, root.bytes)
    assert {:ok, page} = Tay.Event.Value.decode(raw)
    [first | rest] = page["children"]
    bad = put_in(page["children"], [%{first | "offset" => root.offset} | rest])
    assert {:ok, bytes} = Tay.Event.Value.encode(bad)
    forged = %{root | bytes: byte_size(bytes), digest: :crypto.hash(:sha256, bytes)}
    bad_read = fn _, _ -> {:ok, bytes} end
    assert {:error, :index_page} = DiskIndex.fetch(bad_read, forged, key(1))
    assert :ok = :file.close(file)
  end

  test "unsorted keys, duplicate keys and I/O failures refuse a build", %{index_file: file} do
    assert {:error, :index_key_order} = DiskIndex.build([{key(2), 2}, {key(1), 1}], write(file))
    assert {:error, :index_key_order} = DiskIndex.build([{key(1), 1}, {key(1), 2}], write(file))
    assert {:error, :enospc} = DiskIndex.build([{key(1), 1}], fn _, _ -> {:error, :enospc} end)
    assert {:ok, root, _} = DiskIndex.build([{key(1), 1}], write(file))
    assert {:error, :eio} = DiskIndex.fetch(fn _, _ -> {:error, :eio} end, root, key(1))
    assert :ok = :file.close(file)
  end
end
