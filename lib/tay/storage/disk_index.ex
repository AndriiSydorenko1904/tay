defmodule Tay.Storage.DiskIndex do
  @moduledoc """
  Immutable authenticated ordered index for checkpoint metadata.

  Pages contain inert Value data. Each parent authenticates its children; the
  root reference must be authenticated by the checkpoint authority. Lookup reads
  only its search path, and pagination reads only the requested range. No ETS
  reconstruction, atoms from storage, filesystem paths or process state are used.

  `build/3` consumes strictly increasing binary keys without sorting or retaining
  values for the whole index. The write callback appends one page and returns
  `:ok`; the read callback returns `{:ok, bytes}` for an exact positional read.
  Publication, fsync and ownership belong to the caller. Failed builds leave
  unpublished bytes which the caller must discard.
  """
  alias Tay.Event.Value

  @fanout 64
  @max_page 16_777_216
  @max_offset 9_223_372_036_854_775_807

  @doc "Encodes a root to embed in authenticated checkpoint metadata."
  def encode_root(root) do
    with :ok <- reference(root),
         do: Value.encode(%{"version" => 1, "root" => if(root, do: wire(root))})
  end

  def decode_root(bytes) do
    with {:ok, %{"version" => 1, "root" => value} = envelope} <- Value.decode(bytes),
         true <- map_size(envelope) == 2 || {:error, :index_root},
         root <- if(is_nil(value), do: nil, else: unwire(value)),
         :ok <- reference(root) do
      {:ok, root}
    else
      {:ok, _} -> {:error, :index_root}
      error -> error
    end
  end

  def build(entries, write, offset \\ 0)
      when is_function(write, 2) and is_integer(offset) and offset >= 0 do
    entries
    |> Enum.reduce_while({:ok, [], [], offset, nil}, fn
      {key, value}, {:ok, batch, pages, position, previous}
      when is_binary(key) and (is_nil(previous) or key > previous) ->
        batch = [[{:bytes, key}, value] | batch]

        if length(batch) == @fanout do
          case leaf(write, Enum.reverse(batch), position) do
            {:ok, ref, next} -> {:cont, {:ok, [], [ref | pages], next, key}}
            error -> {:halt, error}
          end
        else
          {:cont, {:ok, batch, pages, position, key}}
        end

      _, _ ->
        {:halt, {:error, :index_key_order}}
    end)
    |> finish_leaves(write)
  end

  def fetch(read, root, key) when is_function(read, 2) and is_binary(key) do
    with :ok <- reference(root) do
      cond do
        is_nil(root) -> :not_found
        key < root.first or key > root.last -> :not_found
        true -> find(read, root, key)
      end
    end
  end

  @doc "Returns at most limit entries in ascending order, strictly after the cursor."
  def page(read, root, after_key \\ nil, limit \\ 50)
      when is_function(read, 2) and (is_nil(after_key) or is_binary(after_key)) and
             is_integer(limit) and limit > 0 do
    with :ok <- reference(root),
         {:ok, entries, _remaining} <- walk(read, root, after_key, limit) do
      {:ok, entries}
    end
  end

  @doc "Visits each authenticated leaf once without materializing the whole index."
  def reduce(read, root, accumulator, reducer) do
    with :ok <- reference(root), do: fold(read, root, accumulator, reducer)
  end

  defp fold(_read, nil, acc, _fun), do: {:ok, acc}

  defp fold(read, ref, acc, fun) do
    with {:ok, node} <- load(read, ref) do
      case node do
        {:leaf, entries} ->
          Enum.reduce_while(entries, {:ok, acc}, fn {key, value}, {:ok, current} ->
            case fun.(key, value, current) do
              {:ok, next} -> {:cont, {:ok, next}}
              error -> {:halt, error}
            end
          end)

        {:children, children} ->
          Enum.reduce_while(children, {:ok, acc}, fn child, {:ok, current} ->
            case fold(read, child, current, fun) do
              {:ok, next} -> {:cont, {:ok, next}}
              error -> {:halt, error}
            end
          end)
      end
    end
  end

  defp finish_leaves({:error, _} = error, _write), do: error

  defp finish_leaves({:ok, batch, pages, offset, _}, write) do
    case batch do
      [] ->
        levels(write, Enum.reverse(pages), offset)

      _ ->
        with {:ok, ref, next} <- leaf(write, Enum.reverse(batch), offset),
             do: levels(write, Enum.reverse([ref | pages]), next)
    end
  end

  defp leaf(write, entries, offset) do
    [{:bytes, first}, _] = hd(entries)
    [{:bytes, last}, _] = List.last(entries)
    emit(write, %{"version" => 1, "leaf" => entries}, offset, first, last, length(entries), 0)
  end

  defp levels(_write, [], offset), do: {:ok, nil, offset}
  defp levels(_write, [root], offset), do: {:ok, root, offset}

  defp levels(write, pages, offset) do
    pages
    |> Enum.chunk_every(@fanout)
    |> Enum.reduce_while({:ok, [], offset}, fn children, {:ok, parents, position} ->
      result =
        emit(
          write,
          %{"version" => 1, "children" => Enum.map(children, &wire/1)},
          position,
          hd(children).first,
          List.last(children).last,
          Enum.sum(Enum.map(children, & &1.count)),
          hd(children).height + 1
        )

      case result do
        {:ok, ref, next} -> {:cont, {:ok, [ref | parents], next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parents, next} -> levels(write, Enum.reverse(parents), next)
      error -> error
    end
  end

  defp emit(write, page, offset, first, last, count, height) do
    with {:ok, bytes} <- Value.encode(page),
         true <- offset + byte_size(bytes) <= @max_offset || {:error, :index_offset},
         :ok <- write.(offset, bytes) do
      {:ok,
       %{
         offset: offset,
         bytes: byte_size(bytes),
         digest: :crypto.hash(:sha256, bytes),
         first: first,
         last: last,
         count: count,
         height: height
       }, offset + byte_size(bytes)}
    end
  end

  defp reference(nil), do: :ok

  defp reference(
         %{
           offset: offset,
           bytes: bytes,
           digest: digest,
           first: first,
           last: last,
           count: count,
           height: height
         } = ref
       )
       when map_size(ref) == 7 do
    if is_integer(offset) and offset >= 0 and is_integer(bytes) and bytes in 1..@max_page and
         offset + bytes <= @max_offset and is_binary(digest) and byte_size(digest) == 32 and
         is_binary(first) and is_binary(last) and first <= last and is_integer(count) and
         count > 0 and is_integer(height) and height >= 0 and height <= offset,
       do: :ok,
       else: {:error, :index_reference}
  end

  defp reference(_), do: {:error, :index_reference}

  defp load(read, ref) do
    with {:ok, bytes} <- read_page(read, ref),
         true <-
           (is_binary(bytes) and byte_size(bytes) == ref.bytes) || {:error, :index_short_read},
         true <- :crypto.hash(:sha256, bytes) == ref.digest || {:error, :index_digest},
         {:ok, value} <- Value.decode(bytes),
         {:ok, node} <- node(value, ref) do
      {:ok, node}
    end
  end

  defp read_page(read, ref) do
    case read.(ref.offset, ref.bytes) do
      :eof -> {:error, :index_short_read}
      result -> result
    end
  end

  defp node(%{"version" => 1, "leaf" => entries} = page, %{height: 0} = ref)
       when map_size(page) == 2 and is_list(entries) do
    pairs =
      Enum.map(entries, fn
        [{:bytes, key}, value] when is_binary(key) -> {key, value}
        _ -> :invalid
      end)

    if length(pairs) in 1..@fanout and Enum.all?(pairs, &is_tuple/1) and
         ordered?(pairs) and elem(hd(pairs), 0) == ref.first and
         elem(List.last(pairs), 0) == ref.last and length(pairs) == ref.count,
       do: {:ok, {:leaf, pairs}},
       else: {:error, :index_page}
  end

  defp node(%{"version" => 1, "children" => entries} = page, ref)
       when map_size(page) == 2 and is_list(entries) and ref.height > 0 do
    children = Enum.map(entries, &unwire/1)

    valid =
      length(children) in 1..@fanout and
        Enum.all?(children, fn child ->
          reference(child) == :ok and not is_nil(child) and
            child.offset + child.bytes <= ref.offset and child.height == ref.height - 1
        end)

    ordered =
      valid and
        children
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.all?(fn [a, b] -> a.last < b.first end)

    if valid and ordered and hd(children).first == ref.first and
         List.last(children).last == ref.last and
         Enum.sum(Enum.map(children, & &1.count)) == ref.count and
         ref.height > 0, do: {:ok, {:children, children}}, else: {:error, :index_page}
  end

  defp node(_, _), do: {:error, :index_page}

  defp ordered?(pairs),
    do:
      pairs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [{a, _}, {b, _}] -> a < b end)

  defp find(read, ref, key) do
    with {:ok, node} <- load(read, ref) do
      case node do
        {:leaf, entries} ->
          case List.keyfind(entries, key, 0) do
            {^key, value} -> {:ok, value}
            nil -> :not_found
          end

        {:children, children} ->
          case Enum.find(children, &(key >= &1.first and key <= &1.last)) do
            nil -> :not_found
            child -> find(read, child, key)
          end
      end
    end
  end

  defp walk(_read, nil, _after, remaining), do: {:ok, [], remaining}
  defp walk(_read, _ref, _after, 0), do: {:ok, [], 0}

  defp walk(_read, %{last: last}, cursor, remaining) when is_binary(cursor) and last <= cursor,
    do: {:ok, [], remaining}

  defp walk(read, ref, cursor, remaining) do
    with {:ok, node} <- load(read, ref) do
      case node do
        {:leaf, entries} ->
          selected =
            entries
            |> Enum.filter(fn {key, _} -> is_nil(cursor) or key > cursor end)
            |> Enum.take(remaining)

          {:ok, selected, remaining - length(selected)}

        {:children, children} ->
          Enum.reduce_while(children, {:ok, [], remaining}, fn child, {:ok, acc, left} ->
            case walk(read, child, cursor, left) do
              {:ok, values, next} -> {:cont, {:ok, acc ++ values, next}}
              error -> {:halt, error}
            end
          end)
      end
    end
  end

  defp wire(ref),
    do: %{
      "offset" => ref.offset,
      "bytes" => ref.bytes,
      "digest" => {:bytes, ref.digest},
      "first" => {:bytes, ref.first},
      "last" => {:bytes, ref.last},
      "count" => ref.count,
      "height" => ref.height
    }

  defp unwire(
         %{
           "offset" => offset,
           "bytes" => bytes,
           "digest" => {:bytes, digest},
           "first" => {:bytes, first},
           "last" => {:bytes, last},
           "count" => count,
           "height" => height
         } = ref
       )
       when map_size(ref) == 7,
       do: %{
         offset: offset,
         bytes: bytes,
         digest: digest,
         first: first,
         last: last,
         count: count,
         height: height
       }

  defp unwire(_), do: :invalid
end
