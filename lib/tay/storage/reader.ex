defmodule Tay.Storage.Reader do
  @moduledoc """
  Physical store discovery and topology validation. No repair or projection.

  Files are visited through the native helper's pinned, read-only descriptors
  under its existing store lock. A physical success does not establish Event
  support. Unknown semantic types remain visible to the future Event layer.
  """
  alias Tay.Storage.{Native, Segment}

  @doc "Discovers and validates all physical history under the existing Port lock."
  def inspect_store(native) do
    with :ok <- Native.check(native),
         {:ok, root_entries} <- Native.list(native, :root),
         {:ok, root} <- classify_entries(root_entries, :root),
         {:ok, segment_entries} <- segment_entries(native),
         {:ok, files} <- classify_entries(segment_entries, :segments) do
      case Map.get(root.entries, "STORE") do
        nil -> uninitialized(native, root, files)
        marker -> initialized(native, marker, files)
      end
    end
  end

  @doc "Reduces physical records with bounded memory; use a pure accumulator function."
  def reduce(native, accumulator, reducer) when is_function(reducer, 3) do
    with {:ok, %{state: :ready} = store} <- inspect_store(native) do
      Enum.reduce_while(store.segments, {:ok, accumulator}, fn segment, {:ok, acc} ->
        {:ok, name} = Segment.filename(segment.id)
        entry = Map.put(segment.identity, :name, name)
        opts = [id: segment.id, store_id: store.store_id, highest: segment.id == store.highest.id]

        case with_file(native, :segments, entry, fn identity ->
               Segment.reduce(&Native.read(native, &1, &2), identity.size, acc, reducer, opts)
             end) do
          {:ok, _, acc} -> {:cont, {:ok, acc}}
          error -> {:halt, error}
        end
      end)
    else
      {:ok, _} -> discovery(:uninitialized_store)
      error -> error
    end
  end

  defp segment_entries(native) do
    case Native.list(native, :segments) do
      {:error, %{reason: "enoent"}} -> {:ok, []}
      other -> other
    end
  end

  defp uninitialized(native, root, files) do
    cond do
      root.unrelated != [] or files.unrelated != [] ->
        discovery(:nonempty_uninitialized_store)

      files.canonical == [] ->
        {:ok,
         %{state: :uninitialized, segments_directory: Map.has_key?(root.entries, "segments")}}

      length(files.canonical) != 1 ->
        discovery(:missing_store_marker)

      true ->
        [{1, entry}] = files.canonical

        with {:ok, segment} <- scan_file(native, entry, id: 1, highest: true),
             true <-
               (segment.state == :active and segment.count == 0 and segment.first_sequence == 1) ||
                 discovery(:missing_store_marker) do
          {:ok, %{state: :genesis, highest: segment, store_id: segment.store_id}}
        end
    end
  end

  defp initialized(native, marker, files) do
    with {:ok, store_id} <-
           with_file(native, :root, marker, fn id ->
             if id.size > 28 do
               {:error,
                %{kind: :corrupt_store, reason: :trailing_store_bytes, offset: 0, segment_id: nil}}
             else
               with {:ok, bytes} <- Native.read(native, 0, id.size) do
                 case Segment.decode_store(bytes) do
                   {:ok, store} ->
                     {:ok, store}

                   reason ->
                     {:error, %{kind: :corrupt_store, reason: reason, offset: 0, segment_id: nil}}
                 end
               end
             end
           end),
         true <- files.canonical != [] || discovery(:missing_history) do
      highest = elem(List.last(files.canonical), 0)

      Enum.reduce_while(files.canonical, {:ok, []}, fn {id, entry}, {:ok, acc} ->
        case scan_file(native, entry, id: id, store_id: store_id, highest: id == highest) do
          {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, segments} ->
          with {:ok, store} <- validate_topology(Enum.reverse(segments)),
               :ok <- Native.check(native) do
            {:ok, Map.put(store, :state, :ready)}
          end

        error ->
          error
      end
    end
  end

  defp scan_file(native, entry, options) do
    with_file(native, :segments, entry, fn identity ->
      case Segment.scan(&Native.read(native, &1, &2), identity.size, options) do
        {:ok, segment} -> {:ok, %{segment | identity: identity}}
        error -> error
      end
    end)
  end

  defp with_file(native, scope, expected, fun) do
    with {:ok, identity} <- Native.open_read(native, scope, expected.name) do
      result =
        if identity.device == expected.device and identity.inode == expected.inode and
             identity.size == expected.size,
           do: fun.(identity),
           else: discovery({:changed_file, expected.name})

      case Native.close_read(native) do
        :ok -> result
        error -> error
      end
    end
  end

  @doc false
  def classify_entries(entries, scope) when is_list(entries) and scope in [:root, :segments] do
    Enum.reduce_while(
      entries,
      {:ok, %{canonical: [], staging: [], unrelated: [], entries: %{}}},
      fn entry, {:ok, acc} ->
        case classify(entry, scope) do
          {:ok, kind, value} ->
            if Map.has_key?(acc.entries, entry.name) do
              {:halt, discovery({:duplicate_name, entry.name})}
            else
              acc = %{acc | entries: Map.put(acc.entries, entry.name, entry)}

              acc =
                if kind in [:canonical, :staging, :unrelated],
                  do: Map.update!(acc, kind, &[value | &1]),
                  else: acc

              {:cont, {:ok, acc}}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end
    )
    |> ordered()
  end

  defp classify(%{name: name, type: type, size: size, links: links} = entry, scope) do
    cond do
      not is_binary(name) or not String.valid?(name) ->
        discovery(:invalid_name_encoding)

      type in [:symlink, :other] ->
        discovery({:unsupported_entry_type, name, type})

      type == :regular and links != 1 ->
        discovery({:hard_link, name})

      scope == :root and name == "segments" and type == :directory ->
        {:ok, :directory, entry}

      scope == :root and name in ["STORE", ".tay-owner.lock"] and type == :regular ->
        {:ok, :metadata, entry}

      String.starts_with?(name, ".tay-new-") or String.starts_with?(name, ".tay-store-") ->
        stage(entry, scope)

      scope == :segments and match?({:ok, _}, Segment.filename_id(name)) and type == :regular ->
        {:ok, id} = Segment.filename_id(name)

        if size == 0,
          do: discovery({:zero_byte_segment, id}),
          else: {:ok, :canonical, {id, entry}}

      String.contains?(String.downcase(name), ".tay") ->
        discovery({:malformed_segment_name, name})

      type != :regular ->
        discovery({:unexpected_directory, name})

      true ->
        {:ok, :unrelated, entry}
    end
  end

  defp classify(_, _), do: discovery(:invalid_entry)

  defp stage(entry, scope) do
    valid =
      case scope do
        :root ->
          Regex.match?(~r/\A\.tay-store-[0-9a-f]{32}\.tmp\z/, entry.name) and entry.size <= 28

        :segments ->
          case Regex.run(~r/\A\.tay-new-([0-9]{20})-[0-9a-f]{32}\.tmp\z/, entry.name) do
            [_, id] -> match?({:ok, _}, Segment.filename_id(id <> ".tay")) and entry.size <= 44
            _ -> false
          end
      end

    if valid and entry.type == :regular,
      do: {:ok, :staging, entry},
      else: discovery({:invalid_staging_file, entry.name})
  end

  defp ordered({:ok, result}) do
    canonical = Enum.sort_by(result.canonical, &elem(&1, 0))
    ids = Enum.map(canonical, &elem(&1, 0))

    if Enum.with_index(ids, 1) |> Enum.all?(fn {id, expected} -> id == expected end),
      do: {:ok, %{result | canonical: canonical}},
      else: discovery({:noncontiguous_ids, ids})
  end

  defp ordered(error), do: error

  @doc "Checks complete segment summaries in numeric order; no suffix can be skipped."
  def validate_topology([]), do: discovery(:missing_history)

  def validate_topology(segments) when is_list(segments) do
    highest = List.last(segments)
    first_store = hd(segments).store_id

    Enum.reduce_while(Enum.with_index(segments, 1), {:ok, 1}, fn {segment, id}, {:ok, next} ->
      cond do
        segment.id != id ->
          {:halt, discovery({:segment_id, id, segment.id})}

        segment.store_id != first_store ->
          {:halt, discovery({:store_identity, id})}

        segment.first_sequence != next ->
          {:halt, discovery({:first_sequence, id, next, segment.first_sequence})}

        segment.id != highest.id and segment.state != :sealed ->
          {:halt, discovery({:earlier_active, id})}

        segment.state not in [:active, :sealed] ->
          {:halt, discovery({:unclassified_segment, id})}

        true ->
          {:cont, {:ok, if(segment.count == 0, do: next, else: segment.last_sequence + 1)}}
      end
    end)
    |> case do
      {:ok, next} ->
        {:ok,
         %{
           segments: segments,
           highest: highest,
           store_id: first_store,
           next_sequence: next,
           exhausted:
             next > Segment.max_id() or
               (highest.state == :sealed and highest.id == Segment.max_id())
         }}

      error ->
        error
    end
  end

  defp discovery(reason),
    do: {:error, %{kind: :discovery_error, reason: reason, segment_id: nil, offset: 0}}
end
