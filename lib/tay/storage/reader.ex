defmodule Tay.Storage.Reader do
  @moduledoc false

  alias Tay.Storage.Segment

  @doc false
  def classify_entries(entries, :segments) when is_list(entries) do
    Enum.reduce_while(
      entries,
      {:ok, %{canonical: [], staging: [], unrelated: [], entries: %{}}},
      fn entry, {:ok, acc} ->
        case classify(entry) do
          {:ok, kind, value} ->
            if Map.has_key?(acc.entries, entry.name) do
              {:halt, discovery({:duplicate_name, entry.name})}
            else
              acc = %{acc | entries: Map.put(acc.entries, entry.name, entry)}
              {:cont, {:ok, Map.update!(acc, kind, &[value | &1])}}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end
    )
    |> ordered()
  end

  defp classify(%{name: name, type: type, size: size, links: links} = entry) do
    cond do
      not is_binary(name) or not String.valid?(name) ->
        discovery(:invalid_name_encoding)

      type in [:symlink, :other] ->
        discovery({:unsupported_entry_type, name, type})

      type == :regular and links != 1 ->
        discovery({:hard_link, name})

      String.starts_with?(name, ".tay-new-") ->
        stage(entry)

      match?({:ok, _}, Segment.filename_id(name)) and type == :regular ->
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

  defp classify(_), do: discovery(:invalid_entry)

  defp stage(entry) do
    valid =
      case Regex.run(~r/\A\.tay-new-([0-9]{20})-[0-9a-f]{32}\.tmp\z/, entry.name) do
        [_, id] -> match?({:ok, _}, Segment.filename_id(id <> ".tay")) and entry.size <= 44
        _ -> false
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
