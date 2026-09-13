defmodule Tay.Storage.ColdCopy do
  @moduledoc """
  Exclusive whole-store cold backup and restore.

  Catalogs are external evidence rather than Tay state. This module never
  repairs, activates, truncates, or mutates its source. It keeps the source's
  existing ownership lock for the full inventory/hash/copy interval and uses
  the native storage helper for every path-sensitive destination operation.
  """

  alias Tay.Storage.Native

  @chunk_bytes 1_048_576
  @catalog_bytes 64 * 1_048_576
  @default_max_files 100_000
  @default_max_bytes 10_737_418_240
  @identity_keys [:size, :device, :inode, :links, :type, :mode, :mtime_ns, :ctime_ns]
  @environment Mix.env()

  @type result :: %{
          required(:result) => String.t(),
          required(:files) => non_neg_integer(),
          required(:files_synced) => non_neg_integer(),
          required(:semantic_validation) => String.t(),
          required(:activation) => String.t()
        }

  def backup(options), do: copy(:backup, options)
  def restore(options), do: copy(:restore, options)

  def copy(operation, options) when operation in [:backup, :restore] do
    with {:ok, config} <- options(operation, options),
         {:ok, source} <- open_source(config) do
      try do
        copy_source(operation, source, config)
      rescue
        _ -> refused(:io_or_invalid_archive)
      catch
        _, _ -> refused(:io_or_invalid_archive)
      after
        Native.shutdown(source)
      end
    end
  end

  def copy(_, _), do: refused(:invalid_options)

  @doc false
  def cli_options(arguments, operation) when operation in [:backup, :restore] do
    switches = [
      source: :string,
      destination: :string,
      catalog: :string,
      verify_catalog: :string,
      durability: :string,
      validated_filesystem: :boolean,
      max_files: :integer,
      max_bytes: :integer
    ]

    {parsed, remaining, invalid} = OptionParser.parse(arguments, strict: switches)

    if remaining == [] and invalid == [] and
         length(parsed) == length(Enum.uniq(Keyword.keys(parsed))) do
      durability = Keyword.get(parsed, :durability, "sync")

      copy(operation,
        source: parsed[:source],
        destination: parsed[:destination],
        catalog: parsed[:catalog],
        verify_catalog: parsed[:verify_catalog],
        durability: durability,
        validated_filesystem: Keyword.get(parsed, :validated_filesystem, false),
        max_files: Keyword.get(parsed, :max_files, @default_max_files),
        max_bytes: Keyword.get(parsed, :max_bytes, @default_max_bytes)
      )
    else
      refused(:invalid_arguments)
    end
  end

  @doc false
  def format(%{result: "refused"} = error), do: json(error)
  def format({:ok, result}), do: json(result)
  def format({:error, error}), do: json(error)
  def format(result) when is_map(result), do: json(result)

  defp copy_source(operation, source, config) do
    with :ok <- native(Native.cold_source(source)),
         {:ok, entries} <- inventory(source, config),
         {:ok, expected} <- hashes(source, entries),
         {:ok, source_info} <- native(Native.info(source)),
         {:ok, target} <- open_target(source_info, config) do
      try do
        with :ok <- verify_catalog(operation, target, expected, config),
             :ok <- inventory_matches(source, entries, config),
             :ok <- test_hook(config, :after_hash),
             :ok <- native(Native.cold_create_stage(target, staging_name(config.destination))),
             :ok <- test_hook(config, :after_stage),
             {:ok, synced} <- copy_entries(source, target, entries, expected, config),
             :ok <- inventory_matches(source, entries, config),
             :ok <- native(Native.check(source)),
             :ok <- native(Native.cold_check(target)),
             :ok <- sync_staging(target, config),
             :ok <- native(Native.cold_publish(target)),
             {:ok, report} <- publish_catalog(target, expected, synced, config) do
          {:ok,
           %{
             result: report["durability"],
             files: map_size(expected),
             files_synced: synced,
             semantic_validation: "required",
             activation: "not_attempted"
           }}
        end
      after
        Native.shutdown(target)
      end
    end
  end

  defp options(operation, input) do
    allowed =
      [
        :source,
        :destination,
        :catalog,
        :verify_catalog,
        :durability,
        :validated_filesystem,
        :max_files,
        :max_bytes
      ] ++ test_option_keys()

    with true <- keyword?(input, allowed),
         input <-
           Keyword.merge(
             [
               durability: :sync,
               validated_filesystem: false,
               max_files: @default_max_files,
               max_bytes: @default_max_bytes
             ],
             input
           ),
         {:ok, source} <- absolute(input[:source]),
         {:ok, destination} <- absolute(input[:destination]),
         {:ok, catalog} <- absolute(input[:catalog]),
         {:ok, verify} <- optional_absolute(input[:verify_catalog]),
         {:ok, durability} <- durability(input[:durability]),
         true <- is_boolean(input[:validated_filesystem]) or {:error, :invalid_options},
         true <-
           durability != :sync or input[:validated_filesystem] or
             {:error, :filesystem_validation_required},
         true <-
           (valid_budget?(input[:max_files]) and valid_budget?(input[:max_bytes])) or
             {:error, :invalid_budget},
         true <- not overlap?(source, destination) or {:error, :overlapping_paths},
         true <- external?(catalog, source, destination) or {:error, :catalog_must_be_external},
         true <-
           is_nil(verify) or external?(verify, source, destination) or
             {:error, :catalog_must_be_external},
         true <- operation != :restore or is_binary(verify) or {:error, :restore_catalog_required} do
      {:ok,
       %{
         source: source,
         destination: destination,
         catalog: catalog,
         verify_catalog: verify,
         durability: durability,
         validated_filesystem: input[:validated_filesystem],
         max_files: input[:max_files],
         max_bytes: input[:max_bytes],
         test_hook: test_hook_option(input)
       }}
    else
      {:error, reason} -> refused(reason)
      _ -> refused(:invalid_options)
    end
  end

  defp keyword?(input, allowed) do
    Keyword.keyword?(input) and
      length(Keyword.keys(input)) == length(Enum.uniq(Keyword.keys(input))) and
      Enum.all?(Keyword.keys(input), &(&1 in allowed)) and
      Enum.all?([:source, :destination, :catalog], &Keyword.has_key?(input, &1))
  end

  defp absolute(path) when is_binary(path) do
    raw_parts = String.split(path, "/", trim: false)

    if Path.type(path) == :absolute and path != "/" and String.valid?(path) and
         byte_size(path) in 1..4095 and not String.contains?(path, <<0>>) and
         not Enum.member?(raw_parts, "..") do
      expanded = Path.expand(path)

      if expanded != "/" and byte_size(expanded) <= 4095,
        do: {:ok, expanded},
        else: {:error, :unsafe_path}
    else
      {:error, :unsafe_path}
    end
  end

  defp absolute(_), do: {:error, :unsafe_path}
  defp optional_absolute(nil), do: {:ok, nil}
  defp optional_absolute(path), do: absolute(path)

  defp durability(:sync), do: {:ok, :sync}
  defp durability(:development), do: {:ok, :write}
  defp durability("sync"), do: {:ok, :sync}
  defp durability("development"), do: {:ok, :write}
  defp durability(_), do: {:error, :invalid_options}
  defp valid_budget?(value), do: is_integer(value) and value > 0

  defp overlap?(left, right), do: inside?(left, right) or inside?(right, left)

  defp external?(path, source, destination),
    do: not inside?(path, source) and not inside?(path, destination)

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  if @environment == :test do
    defp test_option_keys, do: [:test_hook]
    defp test_hook_option(input), do: Keyword.get(input, :test_hook)
    defp test_hook(%{test_hook: nil}, _phase), do: :ok

    defp test_hook(%{test_hook: hook}, phase) when is_function(hook, 1), do: hook.(phase)
    defp test_hook(_config, _phase), do: refused(:invalid_test_hook)
  else
    defp test_option_keys, do: []
    defp test_hook_option(_input), do: nil
    defp test_hook(_config, _phase), do: :ok
  end

  defp open_source(config) do
    Native.open_existing(config.source,
      durability: config.durability,
      validated_filesystem: config.validated_filesystem,
      max_directory_entries: config.max_files
    )
    |> native(:source)
  end

  defp open_target(source, config) do
    Native.open_cold_target(source, config.destination, config.catalog, config.verify_catalog,
      durability: config.durability,
      validated_filesystem: config.validated_filesystem
    )
    |> native(:destination)
  end

  defp inventory(source, config) do
    with {:ok, root} <- native(Native.cold_list(source, :root, config.max_files)),
         {:ok, root_entries, seen, bytes, true} <- inventory_root(root, config),
         remaining = config.max_files - seen,
         true <- remaining > 0 or {:error, :file_budget},
         {:ok, segments} <- native(Native.cold_list(source, :segments, remaining)),
         {:ok, entries, _seen, _bytes} <-
           inventory_segments(segments, root_entries, seen, bytes, config),
         true <-
           (Map.has_key?(entries, "STORE") and Map.has_key?(entries, ".tay-owner.lock")) or
             {:error, :missing_metadata},
         true <-
           (Enum.any?(Map.keys(entries), &String.starts_with?(&1, "segments/")) and
              Enum.any?(
                Map.keys(entries),
                &(String.starts_with?(&1, "segments/") and String.ends_with?(&1, ".tay"))
              )) or
             {:error, :missing_history} do
      {:ok, entries}
    else
      {:error, %{result: "refused"} = error} -> {:error, error}
      {:error, reason} -> refused(reason)
      _ -> refused(:missing_segments)
    end
  end

  defp inventory_root(entries, config) do
    Enum.reduce_while(entries, {:ok, %{}, 0, 0, false}, fn entry,
                                                           {:ok, acc, count, bytes, segments?} ->
      with :ok <- name(entry.name),
           {:ok, next_count} <- count(count, config.max_files),
           {:ok, acc, next_bytes, next_segments?} <-
             root_entry(entry, acc, bytes, segments?, config) do
        {:cont, {:ok, acc, next_count, next_bytes, next_segments?}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp root_entry(%{name: "segments", type: :directory}, acc, bytes, _segments?, _config),
    do: {:ok, acc, bytes, true}

  defp root_entry(%{name: "segments"}, _acc, _bytes, _segments?, _config),
    do: {:error, :missing_segments}

  defp root_entry(entry, acc, bytes, segments?, config) do
    with :ok <- regular(entry),
         {:ok, next_bytes} <- bytes(bytes, entry.size, config.max_bytes) do
      {:ok, Map.put(acc, entry.name, entry), next_bytes, segments?}
    end
  end

  defp inventory_segments(entries, acc, seen, bytes, config) do
    Enum.reduce_while(entries, {:ok, acc, seen, bytes}, fn entry,
                                                           {:ok, current, count, byte_count} ->
      with :ok <- name(entry.name),
           {:ok, next_count} <- count(count, config.max_files),
           :ok <- regular(entry),
           {:ok, next_bytes} <- bytes(byte_count, entry.size, config.max_bytes) do
        {:cont, {:ok, Map.put(current, "segments/" <> entry.name, entry), next_count, next_bytes}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp count(count, maximum) when count < maximum, do: {:ok, count + 1}
  defp count(_, _), do: {:error, :file_budget}

  # The native list call receives the configured cap. This extra check makes
  # the semantic budget independent of the helper's packet representation.
  defp bytes(total, size, maximum)
       when is_integer(size) and size >= 0 and total + size <= maximum,
       do: {:ok, total + size}

  defp bytes(_, _, _), do: {:error, :byte_budget}

  defp name(name) when is_binary(name) and name not in ["", ".", ".."] do
    if String.valid?(name) and not String.contains?(name, ["/", <<0>>]),
      do: :ok,
      else: {:error, :unsafe_name}
  end

  defp name(_), do: {:error, :unsafe_name}
  defp regular(%{type: :regular, links: 1}), do: :ok
  defp regular(_), do: {:error, :unsafe_file}

  defp hashes(source, entries) do
    Enum.reduce_while(Enum.sort(entries), {:ok, %{}}, fn {relative, identity}, {:ok, acc} ->
      case hash_file(source, relative, identity) do
        {:ok, digest} ->
          {:cont, {:ok, Map.put(acc, relative, %{"bytes" => identity.size, "sha256" => digest})}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp hash_file(source, relative, expected) do
    with_read(source, scope(relative), basename(relative), expected, fn chunk, digest ->
      {:ok, :crypto.hash_update(digest, chunk)}
    end)
    |> case do
      {:ok, digest} -> {:ok, :crypto.hash_final(digest) |> Base.encode16(case: :lower)}
      error -> error
    end
  end

  defp with_read(native, scope, name, expected, callback) do
    case Native.open_read(native, scope, name) |> native() do
      {:ok, identity} ->
        if same_identity?(identity, expected) do
          result = consume(native, expected.size, :crypto.hash_init(:sha256), callback)
          closed = Native.close_read(native) |> native()

          with {:ok, value} <- result,
               :ok <- closed,
               :ok <- current_identity(native, scope, name, expected) do
            {:ok, value}
          end
        else
          _ = Native.close_read(native)
          refused(:source_changed)
        end

      error ->
        error
    end
  end

  defp consume(native, expected, acc, callback), do: consume(native, expected, 0, acc, callback)

  defp consume(native, expected, offset, acc, callback) do
    length = min(@chunk_bytes, expected - offset + 1)

    case Native.read(native, offset, length) |> native() do
      {:ok, <<>>} when offset == expected ->
        {:ok, acc}

      {:ok, <<>>} ->
        refused(:source_changed)

      {:ok, bytes} when offset + byte_size(bytes) <= expected ->
        with {:ok, next} <- callback.(bytes, acc) do
          consume(native, expected, offset + byte_size(bytes), next, callback)
        end

      {:ok, _} ->
        refused(:source_changed)

      error ->
        error
    end
  end

  defp current_identity(native, scope, name, expected) do
    case Native.open_read(native, scope, name) |> native() do
      {:ok, identity} ->
        closed = Native.close_read(native) |> native()

        if same_identity?(identity, expected) and closed == :ok,
          do: :ok,
          else: refused(:source_changed)

      error ->
        error
    end
  end

  defp inventory_matches(source, expected, config) do
    with {:ok, actual} <- inventory(source, config),
         true <- exact_inventory?(actual, expected) or {:error, :source_changed} do
      :ok
    else
      {:error, %{result: "refused"} = error} -> {:error, error}
      {:error, reason} -> refused(reason)
    end
  end

  defp exact_inventory?(left, right) when map_size(left) == map_size(right) do
    Enum.all?(left, fn {path, identity} -> same_identity?(identity, Map.get(right, path)) end)
  end

  defp exact_inventory?(_, _), do: false

  defp same_identity?(left, right) when is_map(left) and is_map(right),
    do: Map.take(left, @identity_keys) == Map.take(right, @identity_keys)

  defp same_identity?(_, _), do: false

  defp verify_catalog(:backup, _target, _expected, _config), do: :ok

  defp verify_catalog(:restore, target, expected, config) do
    with {:ok, bytes} <- read_catalog(target, config.verify_catalog),
         {:ok, files} <- parse_catalog(bytes, config.max_files),
         true <- files == expected or {:error, :archive_checksum_mismatch} do
      :ok
    else
      {:error, %{result: "refused"} = error} -> {:error, error}
      {:error, reason} -> refused(reason)
    end
  end

  defp read_catalog(target, path) do
    case Native.open_read(target, :verify, Path.basename(path)) |> native() do
      {:ok, %{size: size} = identity} when size <= @catalog_bytes ->
        result = consume(target, size, [], fn chunk, acc -> {:ok, [chunk | acc]} end)
        closed = Native.close_read(target) |> native()

        with {:ok, chunks} <- result,
             :ok <- closed,
             :ok <- current_identity(target, :verify, Path.basename(path), identity) do
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        end

      {:ok, _} ->
        _ = Native.close_read(target)
        refused(:catalog_budget)

      error ->
        error
    end
  end

  defp parse_catalog(bytes, maximum) do
    try do
      case :json.decode(bytes) do
        %{"version" => 1, "files" => files} when is_map(files) and map_size(files) <= maximum ->
          if valid_catalog_files?(files), do: {:ok, files}, else: refused(:invalid_catalog)

        _ ->
          refused(:invalid_catalog)
      end
    rescue
      _ -> refused(:invalid_catalog)
    end
  end

  defp valid_catalog_files?(files) do
    Enum.all?(files, fn
      {path, %{"bytes" => bytes, "sha256" => digest} = entry}
      when is_binary(path) and is_integer(bytes) and bytes >= 0 and is_binary(digest) ->
        map_size(entry) == 2 and byte_size(digest) == 64 and digest =~ ~r/\A[0-9a-f]{64}\z/

      _ ->
        false
    end)
  end

  defp copy_entries(source, target, entries, expected, config) do
    entries
    |> Map.keys()
    |> Enum.sort_by(&{&1 == "STORE", &1})
    |> Enum.reduce_while({:ok, 0}, fn relative, {:ok, synced} ->
      :ok = test_hook(config, {:before_copy, relative})

      case copy_entry(source, target, relative, entries[relative], expected[relative], config) do
        {:ok, did_sync} -> {:cont, {:ok, synced + did_sync}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp copy_entry(source, target, relative, identity, expected, config) do
    scope = scope(relative)
    name = basename(relative)

    case Native.open_read(source, scope, name) |> native() do
      {:ok, opened} ->
        if same_identity?(opened, identity) do
          with {:ok, _} <-
                 native(
                   Native.cold_open_write(
                     target,
                     target_scope(relative),
                     name,
                     relative == ".tay-owner.lock"
                   )
                 ),
               {:ok, {digest, _offset}} <-
                 consume(source, identity.size, {:crypto.hash_init(:sha256), 0}, fn chunk,
                                                                                    {hash, offset} ->
                   with {:ok, _} <- native(Native.write(target, offset, chunk)),
                        :ok <-
                          test_hook(
                            config,
                            {:after_copy_chunk, relative, offset + byte_size(chunk)}
                          ) do
                     {:ok, {:crypto.hash_update(hash, chunk), offset + byte_size(chunk)}}
                   end
                 end),
               true <-
                 Base.encode16(:crypto.hash_final(digest), case: :lower) == expected["sha256"] or
                   {:error, :source_changed},
               :ok <- close_source(source),
               :ok <- current_identity(source, scope, name, identity),
               :ok <- sync_file(target, config),
               :ok <- native(Native.close_write(target)) do
            {:ok, if(config.durability == :sync, do: 1, else: 0)}
          else
            {:error, reason} -> close_copy_descriptors(source, target, reason)
            _ -> close_copy_descriptors(source, target, :source_changed)
          end
        else
          _ = Native.close_read(source)
          refused(:source_changed)
        end

      error ->
        error
    end
  end

  defp close_source(source), do: Native.close_read(source) |> native()

  defp close_copy_descriptors(source, target, reason) do
    _ = Native.close_read(source)
    _ = Native.close_write(target)

    case reason do
      %{result: "refused"} = error -> {:error, error}
      _ -> refused(reason)
    end
  end

  defp sync_file(_target, %{durability: :write}), do: :ok
  defp sync_file(target, %{durability: :sync}), do: Native.sync(target) |> native()

  defp sync_staging(_target, %{durability: :write}), do: :ok

  defp sync_staging(target, %{durability: :sync}),
    do: Native.cold_sync_staging(target) |> native()

  defp publish_catalog(target, expected, synced, config) do
    report = %{
      "version" => 1,
      "files" => expected,
      "durability" => if(config.durability == :sync, do: "synced_copy", else: "development_copy"),
      "filesystem" => if(config.durability == :sync, do: target.facts.filesystem, else: :null),
      "semantic_validation" => "required",
      "source_rpo" => "catalog_history_only",
      "sync_order" =>
        if(config.durability == :sync,
          do: [
            "every_file",
            "segments_directory",
            "store_directory",
            "publication",
            "ancestors",
            "external_catalog"
          ],
          else: []
        ),
      "files_synced" => synced
    }

    bytes = IO.iodata_to_binary([:json.encode(report), "\n"])

    with {:ok, _} <-
           native(Native.cold_open_write(target, :catalog, Path.basename(config.catalog))),
         {:ok, _} <- write_bytes(target, bytes),
         :ok <- sync_file(target, config),
         :ok <- native(Native.close_write(target)),
         :ok <- sync_catalog(target, config) do
      {:ok, report}
    else
      {:error, %{result: "refused"} = error} ->
        _ = Native.close_write(target)
        {:error, error}

      {:error, reason} ->
        _ = Native.close_write(target)
        refused(reason)
    end
  end

  defp write_bytes(target, bytes) do
    bytes
    |> chunk_binary()
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, offset} ->
      case Native.write(target, offset, chunk) |> native() do
        {:ok, _} -> {:cont, {:ok, offset + byte_size(chunk)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp chunk_binary(<<>>), do: []
  defp chunk_binary(bytes), do: chunk_binary(bytes, [])

  defp chunk_binary(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_binary(bytes, acc) when byte_size(bytes) <= @chunk_bytes,
    do: Enum.reverse([bytes | acc])

  defp chunk_binary(<<chunk::binary-size(@chunk_bytes), rest::binary>>, acc),
    do: chunk_binary(rest, [chunk | acc])

  defp sync_catalog(_target, %{durability: :write}), do: :ok

  defp sync_catalog(target, %{durability: :sync}),
    do: Native.cold_sync_catalog(target) |> native()

  defp scope(relative),
    do: if(String.starts_with?(relative, "segments/"), do: :segments, else: :root)

  defp target_scope(relative),
    do: if(String.starts_with?(relative, "segments/"), do: :segments, else: :root)

  defp basename(relative), do: Path.basename(relative)

  defp staging_name(destination),
    do:
      "." <>
        Path.basename(destination) <>
        ".tay-copy-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp native({:error, %{reason: "store_busy"}}, :source), do: refused(:source_owned)
  defp native({:error, %{reason: "eexist"}}, :destination), do: refused(:destination_exists)
  defp native({:error, error}, _scope), do: native({:error, error})
  defp native({:ok, value}, _scope), do: {:ok, value}

  defp native(:ok), do: :ok
  defp native({:ok, value}), do: {:ok, value}
  defp native({:error, %{reason: "resource_limit"}}), do: refused(:file_budget)
  defp native({:error, %{reason: "hard_link"}}), do: refused(:unsafe_file)
  defp native({:error, %{reason: "eexist"}}), do: refused(:destination_exists)

  defp native({:error, %{reason: "path_or_extent_changed"}}), do: refused(:source_changed)

  defp native({:error, %{reason: reason}}) when reason in ["eloop", "enotdir"],
    do: refused(:unsafe_path)

  defp native({:error, _error}), do: refused(:io_or_invalid_archive)

  defp refused(reason),
    do:
      {:error,
       %{result: "refused", reason: reason, action: "preserve_source_and_partial_destination"}}

  defp json(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
