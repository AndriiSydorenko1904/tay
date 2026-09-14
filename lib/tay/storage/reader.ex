defmodule Tay.Storage.Reader do
  @moduledoc """
  Physical store discovery and topology validation. No repair or projection.

  Files are visited through the native helper's pinned, read-only descriptors
  under its existing store lock. A physical success does not establish Event
  support. Unknown semantic types remain visible to the future Event layer.
  """
  alias Tay.Storage.{Native, Segment}
  alias Tay.Storage.Recovery
  alias Tay.Storage.Recovery.Error

  @doc "Resource-bounded complete physical validation, with a session-local frozen view."
  def preflight(native, options \\ []) do
    with {:ok, opts} <- Recovery.options(options) do
      native = Recovery.bounded_native(native, opts)

      with :ok <- Native.check(native),
           {:ok, root_entries, segment_entries, root, files} <- inventory(native, opts),
           :ok <- total_budget(files, opts),
           {:ok, marker} <- existing_marker(root),
           {:ok, {store_id, marker_bytes}} <-
             recovery_file(native, :root, marker, fn identity ->
               with {:ok, bytes} <- Native.read(native, 0, min(identity.size, 29)) do
                 case Segment.decode_store(bytes) do
                   {:ok, id} -> {:ok, {id, bytes}}
                   reason -> {:error, %{kind: :corrupt_store, reason: reason, offset: 0}}
                 end
               end
             end),
           {:ok, segments} <- preflight_segments(native, files.canonical, store_id, opts),
           {:ok, store} <- validate_topology(segments),
           :ok <- unchanged_inventory(native, opts, root_entries, segment_entries),
           :ok <- Native.check(native) do
        {:ok,
         %{
           generation: native.generation,
           store: Map.put(store, :state, :ready),
           marker: marker_bytes,
           marker_identity: marker,
           root_entries: root_entries,
           segment_entries: segment_entries,
           staging_count: length(root.staging) + length(files.staging),
           ignored_count: length(root.unrelated) + length(files.unrelated)
         }}
      end
    end
  end

  @doc "Stops on visitor error; success requires the entire same-session physical view."
  def reduce_while(native, view, accumulator, visitor, options \\ []) do
    with {:ok, opts} <- Recovery.options(options),
         true <-
           is_function(visitor, 3) || {:error, Error.new(:argument, :invalid_visitor, :replay)},
         true <- view.generation == native.generation || changed(:foreign_view) do
      native = Recovery.bounded_native(native, opts)

      result =
        Enum.reduce_while(view.store.segments, {:ok, accumulator}, fn segment, {:ok, acc} ->
          entry = Map.put(segment.identity, :name, elem(Segment.filename(segment.id), 1))
          options = scan_options(segment.id, view.store.store_id, view.store.highest.id, opts)

          consume = fn record, offset, {state, expected_sequence} ->
            position = %{
              store_id: view.store.store_id,
              segment_id: segment.id,
              record_offset: offset,
              next_offset: offset + 28 + byte_size(record.payload),
              sequence: record.sequence
            }

            with true <- record.sequence == expected_sequence || changed(:replay_sequence),
                 :ok <- Recovery.check_deadline(native) do
              case visitor.(record, position, state) do
                {:cont, next} -> {:cont, {next, expected_sequence + 1}}
                {:error, _} = error -> error
                _ -> {:error, Error.new(:callback, :invalid_visitor_result, :replay)}
              end
            end
          end

          case recovery_file(native, :segments, entry, fn identity ->
                 case Segment.reduce_while(
                        &Native.read(native, &1, &2),
                        identity.size,
                        {acc, segment.first_sequence},
                        consume,
                        options
                      ) do
                   {:ok, actual, {final, _}} ->
                     if %{actual | identity: identity} == segment,
                       do: {:ok, final},
                       else: changed(:segment_content)

                   error ->
                     error
                 end
               end) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
        end)

      with {:ok, final} <- result,
           :ok <- unchanged_inventory(native, opts, view.root_entries, view.segment_entries),
           {:ok, marker} <-
             recovery_file(native, :root, view.marker_identity, fn identity ->
               Native.read(native, 0, identity.size)
             end),
           true <- marker == view.marker || changed(:store_marker),
           :ok <- Native.check(native),
           do: {:ok, final}
    end
  end

  defp inventory(native, opts) do
    with {:ok, root_entries} <- Native.list(native, :root),
         {:ok, root_entries} <- bounded_entries(root_entries, native, opts),
         {:ok, root} <- classify_entries(root_entries, :root),
         :ok <- refuse_v2_root(root),
         {:ok, segment_entries} <- segment_entries(native),
         {:ok, segment_entries} <- bounded_entries(segment_entries, native, opts),
         {:ok, files} <- classify_entries(segment_entries, :segments) do
      {:ok, root_entries, segment_entries, root, files}
    end
  end

  defp bounded_entries(entries, native, opts) do
    if length(entries) > opts.max_directory_entries do
      {:error, Error.new(:resource_limit, :max_directory_entries, :preflight)}
    else
      # Native enumeration is bounded by the reply timeout and packet/entry caps.
      # Check the cooperative deadline while processing the returned entries too.
      Enum.reduce_while(entries, :ok, fn _, :ok ->
        case Recovery.check_deadline(native) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> {:ok, Enum.sort_by(entries, & &1.name)}
        error -> error
      end
    end
  end

  defp total_budget(files, opts) do
    total = Enum.reduce(files.canonical, 0, fn {_, entry}, sum -> sum + entry.size end)
    Recovery.budget(total, opts.max_total_segment_bytes, :max_total_segment_bytes, :preflight)
  end

  defp existing_marker(root) do
    case Map.get(root.entries, "STORE") do
      nil -> {:error, Error.new(:initialization_required, :missing_store_marker, :preflight)}
      marker -> {:ok, marker}
    end
  end

  defp preflight_segments(native, canonical, store_id, opts) do
    highest =
      case List.last(canonical) do
        {id, _} -> id
        nil -> nil
      end

    Enum.reduce_while(canonical, {:ok, [], 0}, fn {id, entry}, {:ok, summaries, count} ->
      visitor = fn _, _, count ->
        with :ok <- Recovery.check_deadline(native),
             :ok <-
               Recovery.budget(
                 count + 1,
                 opts.max_replay_records,
                 :max_replay_records,
                 :preflight
               ),
             do: {:cont, count + 1}
      end

      result =
        recovery_file(native, :segments, entry, fn identity ->
          case Segment.reduce_while(
                 &Native.read(native, &1, &2),
                 identity.size,
                 count,
                 visitor,
                 scan_options(id, store_id, highest, opts)
               ) do
            {:ok, segment, count} -> {:ok, %{segment | identity: identity}, count}
            error -> error
          end
        end)

      case result do
        {:ok, segment, count} -> {:cont, {:ok, [segment | summaries], count}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries, _} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp scan_options(id, store_id, highest, opts),
    do: [
      id: id,
      store_id: store_id,
      highest: id == highest,
      max_decode_payload_bytes: opts.max_decode_payload_bytes
    ]

  defp unchanged_inventory(native, opts, root, segments) do
    with {:ok, actual_root, actual_segments, _, _} <- inventory(native, opts) do
      if actual_root == root and actual_segments == segments, do: :ok, else: changed(:inventory)
    end
  end

  # Catch all catchable callback failures inside the FD scope, then close on
  # every path. Untrappable owner death closes the linked helper and all its FDs.
  defp recovery_file(native, scope, expected, fun) do
    with {:ok, identity} <- Native.open_read(native, scope, expected.name) do
      result =
        try do
          if Map.take(identity, [:device, :inode, :size, :links, :type]) ==
               Map.take(expected, [:device, :inode, :size, :links, :type]),
             do: fun.(identity),
             else: changed(:file_identity)
        catch
          kind, _ -> {:error, Error.new(:callback, {:callback_failed, kind}, :replay)}
        end

      case Native.close_read(%{native | deadline: nil}) do
        :ok ->
          result

        {:error, cleanup} ->
          # A failed close does not establish descriptor release. End the helper
          # session instead of retrying a close with an unknown outcome.
          Native.close(native)

          case result do
            {:error, primary} ->
              error = Error.wrap(primary, :replay)
              {:error, %{error | cleanup_error: Error.bounded(cleanup)}}

            _ ->
              {:error, cleanup}
          end
      end
    end
  end

  defp changed(reason), do: {:error, Error.new(:changed_view, reason, :revalidation)}

  @doc "Discovers and validates all physical history under the existing Port lock."
  def inspect_store(native) do
    with :ok <- Native.check(native),
         {:ok, root_entries} <- Native.list(native, :root),
         {:ok, root} <- classify_entries(root_entries, :root),
         :ok <- refuse_v2_root(root),
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

  # The V1 physical path must never treat an adopted or partially adopted V2
  # root as ordinary V1 history. V2 recovery selects CURRENT separately.
  defp refuse_v2_root(root) do
    if Map.has_key?(root.entries, "STORE-V2") or Map.has_key?(root.entries, "CURRENT"),
      do: discovery(:store_v2_requires_v2_recovery),
      else: :ok
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

      scope == :root and name == "epochs" and type == :directory ->
        {:ok, :directory, entry}

      scope == :root and name in ["STORE", ".tay-owner.lock"] and type == :regular ->
        {:ok, :metadata, entry}

      String.starts_with?(name, ".tay-new-") or String.starts_with?(name, ".tay-store-") or
          (scope == :root and
             (String.starts_with?(name, ".tay-adoption-") or
                String.starts_with?(name, ".tay-v2-marker-") or
                String.starts_with?(name, ".tay-current-"))) ->
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
          (Regex.match?(~r/\A\.tay-store-[0-9a-f]{32}\.tmp\z/, entry.name) and
             entry.size <= 28) or
            (Regex.match?(~r/\A\.tay-adoption-[0-9a-f]{32}\.tmp\z/, entry.name) and
               entry.size <= 28) or
            (Regex.match?(~r/\A\.tay-v2-marker-[0-9a-f]{32}\.tmp\z/, entry.name) and
               entry.size <= 28) or
            (Regex.match?(~r/\A\.tay-current-[0-9a-f]{32}\.tmp\z/, entry.name) and
               entry.size <= 76)

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
