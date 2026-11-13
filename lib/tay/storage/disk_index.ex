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

  def fetch(read, root, key)
      when (is_function(read, 2) or is_function(read, 3)) and is_binary(key) do
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
      when (is_function(read, 2) or is_function(read, 3)) and
             (is_nil(after_key) or is_binary(after_key)) and
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

  @doc "Appends only changed search paths; prior roots and their pages remain immutable."
  def update(read, write, root, changes, offset, epoch \\ nil) do
    with :ok <- reference(root),
         true <- is_nil(epoch) or (is_binary(epoch) and byte_size(epoch) == 16) do
      with {:ok, changes} <- normalize_changes(changes),
           {:ok, refs, next} <- change_many(read, write, root, Enum.sort(changes), offset, epoch),
           do: update_root(write, refs, next, epoch)
    else
      false -> {:error, :index_epoch}
      error -> error
    end
  end

  @doc false
  def inspect_node(read, root) do
    with :ok <- reference(root),
         true <- not is_nil(root) || {:error, :index_reference},
         do: load(read, root)
  end

  defp normalize_changes(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn
      {key, action}, {:ok, acc}
      when is_binary(key) and
             (action == :delete or
                (is_tuple(action) and tuple_size(action) == 2 and elem(action, 0) == :put)) ->
        {:cont, {:ok, Map.put(acc, key, action)}}

      _, _ ->
        {:halt, {:error, :index_change}}
    end)
  end

  defp change_many(_read, _write, ref, [], offset, _epoch),
    do: {:ok, if(ref, do: [ref], else: []), offset}

  defp change_many(_read, write, nil, changes, offset, epoch) do
    emit_leaves(write, for({key, {:put, value}} <- changes, do: {key, value}), offset, epoch)
  end

  defp change_many(read, write, ref, changes, offset, epoch) do
    with {:ok, node} <- load(read, ref) do
      case node do
        {:leaf, pairs} ->
          next =
            Enum.reduce(changes, Map.new(pairs), fn
              {key, :delete}, acc -> Map.delete(acc, key)
              {key, {:put, value}}, acc -> Map.put(acc, key, value)
            end)
            |> Enum.sort()

          if next == pairs,
            do: {:ok, [ref], offset},
            else: emit_leaves(write, next, offset, epoch)

        {:children, children} ->
          grouped =
            Enum.group_by(changes, fn {key, _} ->
              Enum.find_index(children, &(key <= &1.last)) || length(children) - 1
            end)

          with {:ok, updated, next} <-
                 Enum.reduce_while(Enum.with_index(children), {:ok, [], offset}, fn {child, index},
                                                                                    {:ok, refs,
                                                                                     at} ->
                   case change_many(read, write, child, Map.get(grouped, index, []), at, epoch) do
                     {:ok, replacement, after_child} ->
                       {:cont, {:ok, refs ++ replacement, after_child}}

                     error ->
                       {:halt, error}
                   end
                 end) do
            if updated == children,
              do: {:ok, [ref], next},
              else: emit_branches(write, updated, next, epoch)
          end
      end
    end
  end

  defp emit_leaves(write, pairs, offset, epoch) do
    emit_groups(pairs, offset, fn group, at ->
      with {:ok, ref, next} <-
             leaf(write, Enum.map(group, fn {key, value} -> [{:bytes, key}, value] end), at),
           do: {:ok, bind_epoch(ref, epoch), next}
    end)
  end

  defp emit_branches(write, children, offset, epoch) do
    emit_groups(children, offset, fn group, at ->
      with {:ok, ref, next} <-
             emit(
               write,
               %{"version" => 1, "children" => Enum.map(group, &wire/1)},
               at,
               hd(group).first,
               List.last(group).last,
               Enum.sum(Enum.map(group, & &1.count)),
               hd(group).height + 1
             ),
           do: {:ok, bind_epoch(ref, epoch), next}
    end)
  end

  defp emit_groups(values, offset, fun) do
    Enum.reduce_while(Enum.chunk_every(values, @fanout), {:ok, [], offset}, fn group,
                                                                               {:ok, refs, at} ->
      case fun.(group, at) do
        {:ok, ref, next} -> {:cont, {:ok, refs ++ [ref], next}}
        error -> {:halt, error}
      end
    end)
  end

  defp update_root(_write, [], offset, _epoch), do: {:ok, nil, offset}
  defp update_root(_write, [root], offset, _epoch), do: {:ok, root, offset}

  defp update_root(write, refs, offset, epoch) do
    with {:ok, parents, next} <- emit_branches(write, refs, offset, epoch),
         do: update_root(write, parents, next, epoch)
  end

  @doc "Moves reachable pages out of one old index file within a read-byte budget."
  def repack(read, write, root, source, offset, epoch, budget) do
    with :ok <- reference(root),
         do: repack_node(read, write, root, object(source, 0, 0), offset, epoch, budget)
  end

  defp repack_node(_read, _write, nil, _object, offset, _epoch, budget),
    do: {:ok, nil, offset, budget}

  defp repack_node(read, write, root, object, offset, epoch, budget) do
    if budget <= 0 or object not in objects(root) do
      {:ok, root, offset, budget}
    else
      with {:ok, node} <- load(read, root) do
        budget = budget - root.bytes

        case node do
          {:leaf, entries} ->
            with {:ok, [next], offset} <- emit_leaves(write, entries, offset, epoch),
                 do: {:ok, next, offset, budget}

          {:children, children} ->
            with {:ok, updated, offset, budget} <-
                   Enum.reduce_while(children, {:ok, [], offset, budget}, fn child,
                                                                             {:ok, acc, at, left} ->
                     case repack_node(read, write, child, object, at, epoch, left) do
                       {:ok, next, at, left} -> {:cont, {:ok, [next | acc], at, left}}
                       error -> {:halt, error}
                     end
                   end),
                 {:ok, [next], offset} <-
                   emit_branches(write, Enum.reverse(updated), offset, epoch),
                 do: {:ok, next, offset, budget}
        end
      end
    end
  end

  def bind_epoch(nil, _epoch), do: nil
  def bind_epoch(ref, nil), do: ref

  def bind_epoch(ref, epoch) do
    ref = Map.put(ref, :epoch, Map.get(ref, :epoch, epoch))

    Map.put(
      ref,
      :objects,
      Enum.sort(Enum.uniq([object(ref.epoch, 0, 0) | Map.get(ref, :objects, [])]))
    )
  end

  def object(epoch, scope, segment, bytes \\ 0),
    do: <<epoch::binary-size(16), scope, segment::64, bytes::64>>

  def objects(nil), do: []
  def objects(ref), do: Map.get(ref, :objects, [])

  def live_bytes(nil), do: %{}
  def live_bytes(root), do: Map.get(root, :live_bytes, %{})

  defp pointer_object(%{"epoch" => {:bytes, epoch}, "segment" => segment} = pointer)
       when byte_size(epoch) == 16 and is_integer(segment),
       do: object(epoch, 1, segment, Map.get(pointer, "segment_bytes", 0))

  defp pointer_object(_), do: nil

  defp page_live(%{"leaf" => entries}) do
    Enum.reduce(entries, %{}, fn
      [_, %{"bytes" => bytes} = value], acc ->
        if key = pointer_object(value), do: Map.update(acc, key, bytes, &(&1 + bytes)), else: acc

      _, acc ->
        acc
    end)
  end

  defp page_live(%{"children" => children}) do
    Enum.reduce(children, %{}, fn child, acc ->
      values = Map.get(child, "live_bytes", [])

      Enum.reduce(values, acc, fn [{:bytes, key}, bytes], current ->
        Map.update(current, key, bytes, &(&1 + bytes))
      end)
    end)
  end

  defp page_objects(%{"leaf" => entries}) do
    Enum.flat_map(entries, fn
      [_, %{"epoch" => {:bytes, epoch}, "segment" => segment} = pointer]
      when byte_size(epoch) == 16 and is_integer(segment) ->
        [object(epoch, 1, segment, Map.get(pointer, "segment_bytes", 0))]

      _ ->
        []
    end)
  end

  defp page_objects(%{"children" => children}) do
    Enum.flat_map(children, fn child ->
      case Map.get(child, "objects") do
        nil -> []
        values -> Enum.map(values, fn {:bytes, value} -> value end)
      end
    end)
  end

  @doc "Visits metadata only in subtrees that reference the selected archive object."
  def reduce_object(read, root, object, initial, reducer) do
    with :ok <- reference(root), do: fold_object(read, root, object, initial, reducer)
  end

  defp fold_object(_read, nil, _object, acc, _reducer), do: {:ok, acc}

  defp fold_object(read, root, object, acc, reducer) do
    if object in objects(root) do
      with {:ok, node} <- load(read, root) do
        case node do
          {:leaf, entries} ->
            Enum.reduce_while(entries, {:ok, acc}, fn {key, value}, {:ok, current} ->
              if pointer_object(value) == object do
                case reducer.(key, value, current) do
                  {:ok, next} -> {:cont, {:ok, next}}
                  error -> {:halt, error}
                end
              else
                {:cont, {:ok, current}}
              end
            end)

          {:children, children} ->
            Enum.reduce_while(children, {:ok, acc}, fn child, {:ok, current} ->
              case fold_object(read, child, object, current, reducer) do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end
            end)
        end
      end
    else
      {:ok, acc}
    end
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
      ref = %{
        offset: offset,
        bytes: byte_size(bytes),
        digest: :crypto.hash(:sha256, bytes),
        first: first,
        last: last,
        count: count,
        height: height
      }

      objects = page_objects(page) |> Enum.uniq() |> Enum.sort()

      ref =
        if objects == [],
          do: ref,
          else: ref |> Map.put(:objects, objects) |> Map.put(:live_bytes, page_live(page))

      {:ok, ref, offset + byte_size(bytes)}
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
       when map_size(ref) in 7..10 do
    if is_integer(offset) and offset >= 0 and is_integer(bytes) and bytes in 1..@max_page and
         offset + bytes <= @max_offset and is_binary(digest) and byte_size(digest) == 32 and
         is_binary(first) and is_binary(last) and first <= last and is_integer(count) and
         count > 0 and is_integer(height) and height >= 0 and height <= offset and
         (not Map.has_key?(ref, :epoch) or
            (is_binary(Map.get(ref, :epoch)) and byte_size(ref.epoch) == 16)) and
         valid_objects?(ref),
       do: :ok,
       else: {:error, :index_reference}
  end

  defp reference(_), do: {:error, :index_reference}

  defp valid_objects?(ref) do
    allowed = [
      :offset,
      :bytes,
      :digest,
      :first,
      :last,
      :count,
      :height,
      :epoch,
      :objects,
      :live_bytes
    ]

    values = Map.get(ref, :objects, [])

    Enum.all?(Map.keys(ref), &(&1 in allowed)) and is_list(values) and
      Enum.all?(values, fn
        <<_::binary-size(16), 0, 0::64, 0::64>> ->
          true

        <<_::binary-size(16), 1, segment::64, bytes::64>> ->
          segment > 0 and bytes <= 1_073_741_824

        _ ->
          false
      end) and values == Enum.sort(Enum.uniq(values)) and
      valid_live?(Map.get(ref, :live_bytes, %{}), values)
  end

  defp valid_live?(live, objects) when is_map(live) do
    Enum.all?(live, fn
      {<<_::binary-size(16), 1, id::64, size::64>> = key, bytes} ->
        id > 0 and key in objects and is_integer(bytes) and bytes >= 0 and
          (size == 0 or bytes <= size)

      _ ->
        false
    end)
  end

  defp valid_live?(_, _), do: false

  defp load(read, ref) do
    with {:ok, bytes} <- read_page(read, ref),
         true <-
           (is_binary(bytes) and byte_size(bytes) == ref.bytes) || {:error, :index_short_read},
         true <- :crypto.hash(:sha256, bytes) == ref.digest || {:error, :index_digest},
         {:ok, value} <- Value.decode(bytes),
         {:ok, node} <- node(value, ref),
         true <- object_summary?(value, ref) || {:error, :index_objects} do
      {:ok, node}
    end
  end

  defp object_summary?(page, ref) do
    if Map.has_key?(ref, :objects) do
      own = if Map.has_key?(ref, :epoch), do: [object(ref.epoch, 0, 0)], else: []

      Enum.sort(Enum.uniq(own ++ page_objects(page))) == ref.objects and
        (not Map.has_key?(ref, :live_bytes) or page_live(page) == ref.live_bytes)
    else
      true
    end
  end

  defp read_page(read, ref) do
    result =
      if is_function(read, 3),
        do: read.(Map.get(ref, :epoch), ref.offset, ref.bytes),
        else: read.(ref.offset, ref.bytes)

    case result do
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
    children = Enum.map(entries, &(unwire(&1) |> inherit_epoch(ref)))

    valid =
      length(children) in 1..@fanout and
        Enum.all?(children, fn child ->
          reference(child) == :ok and not is_nil(child) and
            (Map.get(child, :epoch) != Map.get(ref, :epoch) or
               child.offset + child.bytes <= ref.offset) and
            child.height == ref.height - 1
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

  defp wire(ref) do
    value = %{
      "offset" => ref.offset,
      "bytes" => ref.bytes,
      "digest" => {:bytes, ref.digest},
      "first" => {:bytes, ref.first},
      "last" => {:bytes, ref.last},
      "count" => ref.count,
      "height" => ref.height
    }

    value =
      if Map.has_key?(ref, :epoch), do: Map.put(value, "epoch", {:bytes, ref.epoch}), else: value

    value =
      if Map.has_key?(ref, :objects),
        do: Map.put(value, "objects", Enum.map(ref.objects, &{:bytes, &1})),
        else: value

    if Map.has_key?(ref, :live_bytes),
      do:
        Map.put(
          value,
          "live_bytes",
          Enum.map(Enum.sort(ref.live_bytes), fn {key, bytes} -> [{:bytes, key}, bytes] end)
        ),
      else: value
  end

  defp inherit_epoch(:invalid, _), do: :invalid
  defp inherit_epoch(child, parent), do: bind_epoch(child, Map.get(parent, :epoch))

  defp unwire(%{"live_bytes" => entries} = value)
       when is_list(entries) and map_size(value) in 8..10 do
    with true <-
           Enum.all?(
             entries,
             &match?([{:bytes, <<_::binary-size(33)>>}, n] when is_integer(n) and n >= 0, &1)
           ),
         pairs <- Enum.map(entries, fn [{:bytes, key}, n] -> {key, n} end),
         true <- pairs == Enum.sort(pairs) and length(pairs) == map_size(Map.new(pairs)),
         ref when is_map(ref) <- unwire(Map.delete(value, "live_bytes")) do
      Map.put(ref, :live_bytes, Map.new(pairs))
    else
      _ -> :invalid
    end
  end

  defp unwire(%{"objects" => values} = ref) when is_list(values) and map_size(ref) in [8, 9] do
    with true <- Enum.all?(values, &match?({:bytes, <<_::binary-size(33)>>}, &1)),
         child when is_map(child) <- unwire(Map.delete(ref, "objects")) do
      Map.put(child, :objects, Enum.map(values, fn {:bytes, value} -> value end))
    else
      _ -> :invalid
    end
  end

  defp unwire(%{"epoch" => {:bytes, epoch}} = ref)
       when map_size(ref) == 8 and byte_size(epoch) == 16 do
    case unwire(Map.delete(ref, "epoch")) do
      :invalid -> :invalid
      child -> Map.put(child, :epoch, epoch)
    end
  end

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
