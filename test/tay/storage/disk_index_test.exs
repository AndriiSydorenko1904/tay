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

  test "bounded metadata repacking eventually releases the source index file", %{index_file: file} do
    source = <<41::128>>
    Process.put(:repack_pages, %{})

    writer = fn epoch ->
      fn at, bytes ->
        Process.put(:repack_pages, Map.put(Process.get(:repack_pages), {epoch, at}, bytes))
        :ok
      end
    end

    reader = fn epoch, at, size ->
      bytes = Map.fetch!(Process.get(:repack_pages), {epoch, at})
      assert byte_size(bytes) == size
      {:ok, bytes}
    end

    {:ok, root, _} = DiskIndex.build(Enum.map(1..200, &{key(&1), &1}), writer.(source), 64)
    root = DiskIndex.bind_epoch(root, source)
    original = root
    object = DiskIndex.object(source, 0, 0)

    root =
      Enum.reduce_while(42..80, root, fn n, root ->
        if object in DiskIndex.objects(root) do
          epoch = <<n::128>>

          assert {:ok, next, _, _} =
                   DiskIndex.repack(reader, writer.(epoch), root, source, 64, epoch, 4_000)

          assert {:ok, 200} = DiskIndex.fetch(reader, next, key(200))
          {:cont, next}
        else
          {:halt, root}
        end
      end)

    refute object in DiskIndex.objects(root)
    assert {:ok, entries} = DiskIndex.page(reader, root, nil, 200)
    assert length(entries) == 200
    assert {:ok, 1} = DiskIndex.fetch(reader, original, key(1))

    assert {:error, :enospc} =
             DiskIndex.repack(
               reader,
               fn _, _ -> {:error, :enospc} end,
               original,
               source,
               64,
               <<99::128>>,
               4_000
             )

    assert {:ok, ^original, 64, 0} =
             DiskIndex.repack(reader, writer.(source), original, source, 64, source, 0)

    :ok = :file.close(file)
  end

  test "copy-on-write updates read and rewrite only changed paths across epochs", %{
    index_file: file
  } do
    first = <<1::128>>
    second = <<2::128>>
    Process.put(:index_pages, %{})
    Process.put(:index_reads, 0)

    writer = fn epoch ->
      fn at, bytes ->
        Process.put(:index_pages, Map.put(Process.get(:index_pages), {epoch, at}, bytes))
        :ok
      end
    end

    read = fn epoch, at, size ->
      Process.put(:index_reads, Process.get(:index_reads) + 1)

      case Map.get(Process.get(:index_pages), {epoch, at}) do
        bytes when is_binary(bytes) and byte_size(bytes) == size -> {:ok, bytes}
        _ -> {:error, :eio}
      end
    end

    {:ok, root, _} = DiskIndex.build(Stream.map(1..9000, &{key(&1), &1}), writer.(first), 64)
    root = DiskIndex.bind_epoch(root, first)
    prior_pages = Process.get(:index_pages)
    changes = [{key(2), :delete}, {key(65), {:put, "changed"}}, {key(9001), {:put, 9001}}]

    assert {:ok, updated, _bytes} =
             DiskIndex.update(read, writer.(second), root, changes, 64, second)

    assert Process.get(:index_reads) <= 3 * (root.height + 1)
    assert map_size(Process.get(:index_pages)) - map_size(prior_pages) <= 3 * (root.height + 2)
    assert Map.take(Process.get(:index_pages), Map.keys(prior_pages)) == prior_pages
    assert updated.count == 9000
    assert {:ok, encoded} = DiskIndex.encode_root(updated)
    assert {:ok, ^updated} = DiskIndex.decode_root(encoded)
    assert {:ok, 2} = DiskIndex.fetch(read, root, key(2))
    assert :not_found = DiskIndex.fetch(read, updated, key(2))
    assert {:ok, "changed"} = DiskIndex.fetch(read, updated, key(65))
    assert {:ok, 9001} = DiskIndex.fetch(read, updated, key(9001))
    assert {:ok, 9000} = DiskIndex.fetch(read, updated, key(9000))
    assert :ok = :file.close(file)
  end

  test "updates preserve roots on no-op, splits, complete deletion and failed writes", %{
    index_file: file
  } do
    {:ok, original, bytes} = DiskIndex.build(Enum.map(1..64, &{key(&1), &1}), write(file))

    assert {:ok, ^original, ^bytes} =
             DiskIndex.update(read(file), write(file), original, [{key(99), :delete}], bytes)

    assert {:ok, ^original, ^bytes} =
             DiskIndex.update(read(file), write(file), original, [{key(1), {:put, 1}}], bytes)

    assert {:ok, split, next} =
             DiskIndex.update(read(file), write(file), original, [{key(65), {:put, nil}}], bytes)

    assert split.height == 1
    assert split.count == 65
    assert {:ok, nil} = DiskIndex.fetch(read(file), split, key(65))

    assert {:error, :enospc} =
             DiskIndex.update(
               read(file),
               fn _, _ -> {:error, :enospc} end,
               split,
               [{key(65), :delete}],
               next
             )

    assert {:ok, nil} = DiskIndex.fetch(read(file), split, key(65))

    assert {:ok, nil, _} =
             DiskIndex.update(
               read(file),
               write(file),
               split,
               Enum.map(1..65, &{key(&1), :delete}),
               next
             )

    assert {:ok, 64} = DiskIndex.fetch(read(file), original, key(64))
    assert :ok = :file.close(file)
  end
end
