defmodule Tay.Storage.V2.RecoveryIndex do
  @moduledoc "Authenticated checkpoint job locations, persisted through the native owner."
  alias Tay.Storage.{DiskIndex, Native, Record, Segment}
  alias Tay.Storage.V2.{Codec, Reducer}
  @max_byte_offset Tay.Limits.int64_max()

  def location(segment, offset, record) do
    %{
      "segment" => segment,
      "offset" => offset,
      "bytes" => byte_size(record.payload) + 28,
      "sequence" => record.sequence,
      "digest" => {:bytes, :crypto.hash(:sha256, record.payload)}
    }
  end

  # Only terminal summaries omit argument bodies. They are authenticated by the
  # published index root; every actual job lookup verifies the original record.
  def location(segment, offset, record, job) do
    pointer = location(segment, offset, record)

    if job.state in [:completed, :cancelled, :discarded] do
      charge =
        case Map.get(job, :charge) do
          %{base_bytes: bytes} ->
            bytes

          _ ->
            {:ok, charged} = Reducer.insert_snapshot(Reducer.candidate(), job)
            charged.jobs[job.id].charge.base_bytes
        end

      summary = put_in(job.definition["args"], %{})
      {:ok, definition_bytes} = Tay.Event.Value.encode(summary.definition)
      summary = %{summary | definition_bytes: definition_bytes}
      {:ok, payload} = Codec.encode_snapshot(summary)

      Map.put(pointer, "summary", %{
        "snapshot" => {:bytes, payload},
        "definition_bytes" => byte_size(job.definition_bytes),
        "charge" => charge
      })
    else
      pointer
    end
  end

  def build(native, entries), do: build(native, entries, [])
  def build(_native, [], []), do: {:ok, nil, 0}

  def build(native, entries, auxiliary) do
    with {:ok, _} <- Native.create_stage(native, :candidate, "RECOVERY"),
         write = fn offset, page ->
           case Native.write(native, offset, page) do
             {:ok, _} -> :ok
             error -> error
           end
         end,
         {:ok, root, bytes} <- DiskIndex.build(entries, write),
         {:ok, aux_root, bytes} <- DiskIndex.build(auxiliary, write, bytes),
         :ok <- Native.sync(native),
         :ok <- Native.close_write(native),
         {:ok, encoded} <- DiskIndex.encode_root(root),
         {:ok, aux_encoded} <- DiskIndex.encode_root(aux_root) do
      {:ok, %{bytes: bytes, root: encoded, auxiliary: aux_encoded}, bytes}
    end
  end

  def valid?(%{format: format} = descriptor) when format in [2, 3],
    do: Tay.Storage.V2.CheckpointIndex.valid?(descriptor)

  def valid?(%{bytes: bytes, root: encoded} = descriptor) when map_size(descriptor) in [2, 3] do
    with true <- Enum.sort(Map.keys(descriptor)) in [[:bytes, :root], [:auxiliary, :bytes, :root]],
         true <- is_integer(bytes) and bytes > 0 and bytes <= @max_byte_offset,
         {:ok, root} <- DiskIndex.decode_root(encoded),
         {:ok, auxiliary} <- DiskIndex.decode_root(Map.get(descriptor, :auxiliary, empty_root())),
         true <- not is_nil(root) or not is_nil(auxiliary),
         last <- auxiliary || root,
         true <- last.offset + last.bytes == bytes,
         true <- is_nil(root) or root.offset + root.bytes <= bytes do
      true
    else
      _ -> false
    end
  end

  def valid?(_), do: false

  def to_value(%{format: format} = descriptor) when format in [2, 3] do
    Map.new(descriptor, fn
      {key, value} when key in [:bytes, :format] -> {Atom.to_string(key), value}
      {key, value} -> {Atom.to_string(key), {:bytes, value}}
    end)
  end

  def to_value(descriptor) do
    Map.new(descriptor, fn
      {:bytes, bytes} -> {"bytes", bytes}
      {key, value} -> {Atom.to_string(key), {:bytes, value}}
    end)
  end

  def from_value(%{"format" => format} = value) when format in [2, 3] do
    keys = [:format, :bytes | Tay.Storage.V2.CheckpointIndex.roles(format)]

    if Enum.sort(Map.keys(value)) == Enum.sort(Enum.map(keys, &Atom.to_string/1)) do
      descriptor =
        Map.new(keys, fn key ->
          encoded = value[Atom.to_string(key)]

          {key,
           case encoded do
             {:bytes, bytes} -> bytes
             scalar -> scalar
           end}
        end)

      if valid?(descriptor), do: {:ok, descriptor}, else: {:error, :checkpoint_descriptor}
    else
      {:error, :checkpoint_descriptor}
    end
  end

  def from_value(%{"bytes" => bytes, "root" => {:bytes, root}} = value)
      when map_size(value) in [2, 3] do
    descriptor =
      case Map.fetch(value, "auxiliary") do
        :error when map_size(value) == 2 -> %{bytes: bytes, root: root}
        {:ok, {:bytes, auxiliary}} -> %{bytes: bytes, root: root, auxiliary: auxiliary}
        _ -> :invalid
      end

    if valid?(descriptor), do: {:ok, descriptor}, else: {:error, :recovery_index_descriptor}
  end

  def from_value(_), do: {:error, :recovery_index_descriptor}

  defp empty_root, do: elem(DiskIndex.encode_root(nil), 1)

  def load(native, descriptor, limits, value_limits) do
    with true <- valid?(descriptor) || {:error, :recovery_index_descriptor},
         true <- Map.has_key?(descriptor, :auxiliary) || {:error, :legacy_recovery_index},
         {:ok, entries} <- Native.list(native, :epoch),
         {:ok, pointers} <-
           with_index(native, :epoch, entries, descriptor, fn read, root ->
             DiskIndex.reduce(read, root, [], fn id, pointer, acc ->
               with true <- byte_size(id) == 16 || {:error, :recovery_index_job},
                    :ok <- pointer?(pointer),
                    do: {:ok, [{id, pointer} | acc]}
             end)
           end),
         {:ok, jobs} <- load_jobs(native, descriptor, pointers, limits, value_limits),
         {:ok, auxiliary} <-
           with_index(
             native,
             :epoch,
             entries,
             %{descriptor | root: descriptor.auxiliary},
             fn read, root ->
               DiskIndex.reduce(read, root, [], fn _key, pointer, acc ->
                 {:ok, [pointer | acc]}
               end)
             end
           ) do
      {:ok, jobs, Enum.reverse(auxiliary)}
    end
  end

  defp load_jobs(native, descriptor, pointers, limits, value_limits) do
    Enum.reduce_while(pointers, {:ok, Reducer.candidate(limits, value_limits)}, fn {id, pointer},
                                                                                   {:ok,
                                                                                    candidate} ->
      result =
        case pointer["summary"] do
          %{"snapshot" => {:bytes, bytes}, "definition_bytes" => size, "charge" => charge}
          when is_integer(size) and size > 0 and is_integer(charge) and charge > 0 ->
            with {:ok, job} <- Codec.decode_snapshot(bytes, value_limits),
                 true <-
                   (job.id == id and job.state in [:completed, :cancelled, :discarded]) ||
                     {:error, :recovery_index_summary},
                 {:ok, next} <- Reducer.insert_snapshot(candidate, job) do
              job =
                next.jobs[id]
                |> Map.put(:cold, true)
                |> Map.put(:definition_size, size)
                |> Map.put(:charge, %{bytes: charge, base_bytes: charge})

              {:ok, put_in(next.jobs[id], job)}
            end

          nil ->
            with {:ok, job} <- fetch(native, descriptor, id),
                 do: Reducer.insert_snapshot(candidate, job)

          _ ->
            {:error, :recovery_index_summary}
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  def read_record(native, pointer) do
    with :ok <- pointer?(Map.delete(pointer, "summary")),
         {:ok, name} <- Segment.filename(pointer["segment"]) do
      with_named_file(native, :segments, name, fn entry ->
        with true <-
               pointer["offset"] + pointer["bytes"] <= entry.size ||
                 {:error, :recovery_index_range},
             {:ok, bytes} <- Native.read(native, pointer["offset"], pointer["bytes"]),
             {:ok, record, <<>>} <- Record.decode(bytes),
             true <- record.sequence == pointer["sequence"] || {:error, :recovery_index_sequence},
             {:bytes, digest} <- pointer["digest"],
             true <-
               :crypto.hash(:sha256, record.payload) == digest || {:error, :recovery_index_digest},
             do: {:ok, record}
      end)
    end
  end

  def verify(native, scope, entries, descriptor, expected, expected_auxiliary \\ nil) do
    with true <- valid?(descriptor) || {:error, :recovery_index_descriptor},
         :ok <- verify_tree(native, scope, entries, descriptor, expected, :jobs) do
      case Map.fetch(descriptor, :auxiliary) do
        {:ok, root} ->
          verify_tree(
            native,
            scope,
            entries,
            %{descriptor | root: root},
            expected_auxiliary,
            :auxiliary
          )

        :error ->
          :ok
      end
    end
  end

  defp verify_tree(native, scope, entries, descriptor, expected, kind) do
    with_index(native, scope, entries, descriptor, fn read, root ->
      count = if root, do: root.count, else: 0

      with true <-
             (is_nil(expected) or count == map_size(expected)) || {:error, :recovery_index_count},
           {:ok, visited} <-
             DiskIndex.reduce(read, root, 0, fn key, pointer, visited ->
               valid =
                 case kind do
                   :jobs ->
                     byte_size(key) == 16 and pointer?(pointer) == :ok

                   :auxiliary ->
                     byte_size(key) == 8 and pointer?(pointer) == :ok and
                       pointer["sequence"] == :binary.decode_unsigned(key)
                 end

               if valid and (is_nil(expected) or Map.get(expected, key) == pointer),
                 do: {:ok, visited + 1},
                 else: {:error, :recovery_index_location}
             end),
           true <- visited == count || {:error, :recovery_index_count},
           do: :ok
    end)
  end

  def fetch(native, %{format: format} = descriptor, id, epoch) when format in [2, 3],
    do: Tay.Storage.V2.CheckpointIndex.fetch(native, descriptor, epoch, id)

  def fetch(native, descriptor, id, _epoch), do: fetch(native, descriptor, id)

  def fetch(native, descriptor, id) when is_binary(id) and byte_size(id) == 16 do
    with true <- valid?(descriptor) || {:error, :recovery_index_descriptor},
         {:ok, entries} <- Native.list(native, :epoch),
         {:ok, pointer} <-
           with_index(native, :epoch, entries, descriptor, fn read, root ->
             DiskIndex.fetch(read, root, id)
           end),
         :ok <- pointer?(pointer),
         {:ok, name} <- Segment.filename(pointer["segment"]) do
      # The native owner pins and validates the named file. The authenticated
      # pointer and record hash bind its contents without listing every segment.
      with_named_file(native, :segments, name, fn entry ->
        with true <-
               pointer["offset"] + pointer["bytes"] <= entry.size ||
                 {:error, :recovery_index_range},
             {:ok, bytes} <- Native.read(native, pointer["offset"], pointer["bytes"]),
             {:ok, %Record{record_type: 7, payload_schema_version: 1} = record, <<>>} <-
               Record.decode(bytes),
             true <- record.sequence == pointer["sequence"] || {:error, :recovery_index_sequence},
             {:bytes, digest} <- pointer["digest"],
             true <-
               :crypto.hash(:sha256, record.payload) == digest || {:error, :recovery_index_digest},
             {:ok, job} <- Codec.decode_snapshot(record.payload),
             true <- job.id == id || {:error, :recovery_index_job} do
          {:ok, job}
        else
          {:error, _} = error -> error
          _ -> {:error, :recovery_index_record}
        end
      end)
    else
      :not_found -> :not_found
      {:error, _} = error -> error
      _ -> {:error, :recovery_index_segment}
    end
  end

  defp pointer?(
         %{
           "segment" => segment,
           "offset" => offset,
           "bytes" => bytes,
           "sequence" => sequence,
           "digest" => {:bytes, digest}
         } = pointer
       )
       when map_size(pointer) in [5, 6] do
    if (map_size(pointer) == 5 or Map.has_key?(pointer, "summary")) and is_integer(segment) and
         segment > 0 and is_integer(offset) and offset >= 44 and
         is_integer(bytes) and bytes in 28..16_777_244 and is_integer(sequence) and sequence > 0 and
         is_binary(digest) and byte_size(digest) == 32,
       do: :ok,
       else: {:error, :recovery_index_pointer}
  end

  defp pointer?(_), do: {:error, :recovery_index_pointer}

  defp with_index(native, scope, entries, descriptor, fun) do
    with %{type: :regular, links: 1, size: size} = entry <-
           Enum.find(entries, &(&1.name == "RECOVERY")),
         true <- size == descriptor.bytes || {:error, :recovery_index_size},
         {:ok, root} <- DiskIndex.decode_root(descriptor.root) do
      with_file(native, scope, entry, fn -> fun.(&Native.read(native, &1, &2), root) end)
    else
      {:error, _} = error -> error
      _ -> {:error, :recovery_index_missing}
    end
  end

  defp with_file(native, scope, entry, fun) do
    with_named_file(native, scope, entry.name, fn opened ->
      result =
        if Map.take(opened, [:size, :device, :inode, :links, :type]) ==
             Map.take(entry, [:size, :device, :inode, :links, :type]),
           do: fun.(),
           else: {:error, :recovery_index_identity}

      result
    end)
  end

  defp with_named_file(native, scope, name, fun) do
    with {:ok, opened} <- Native.open_read(native, scope, name) do
      result = fun.(opened)

      case Native.close_read(native) do
        :ok -> result
        error -> error
      end
    end
  end
end
