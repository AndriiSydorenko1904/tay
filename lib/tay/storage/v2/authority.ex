defmodule Tay.Storage.V2.Authority do
  @moduledoc """
  Pure Store-v2 authority metadata. These bytes do not by themselves authorize
  publication; the native owner must durably create and revalidate the files.
  """

  alias Tay.Event.V1
  alias Tay.Event.Value
  alias Tay.Storage.CRC32C
  alias Tay.Storage.V2.Retention

  @max 18_446_744_073_709_551_615
  @manifest_keys ~w(store_id epoch_id source_epoch_id source_frontier captured_at terminal_retention source_segments base_segments tail_segment_id tail_first_sequence)
  @source_keys ~w(id digest)
  @base_keys ~w(id first_sequence last_sequence bytes digest)

  def encode_marker(store_id) do
    if V1.id?(store_id),
      do: {:ok, checked(<<"TAY2", 1, 0::24, store_id::binary>>)},
      else: {:error, :store_id}
  end

  def decode_marker(bytes) do
    with {:ok, <<"TAY2", 1, 0::24, store_id::binary-size(16)>>} <-
           checked_body(bytes, 24),
         true <- V1.id?(store_id) || {:error, :store_id} do
      {:ok, store_id}
    else
      {:ok, _} -> {:error, :marker_format}
      error -> error
    end
  end

  def encode_current(%{store_id: store_id, epoch_id: epoch_id, manifest_digest: digest}) do
    if V1.id?(store_id) and V1.id?(epoch_id) and digest?(digest) do
      {:ok, checked(<<"TAYC", 1, 0::24, store_id::binary, epoch_id::binary, digest::binary>>)}
    else
      {:error, :current_fields}
    end
  end

  def encode_current(_), do: {:error, :current_fields}

  def decode_current(bytes) do
    with {:ok,
          <<"TAYC", 1, 0::24, store_id::binary-size(16), epoch_id::binary-size(16),
            digest::binary-size(32)>>} <- checked_body(bytes, 72),
         true <- (V1.id?(store_id) and V1.id?(epoch_id)) || {:error, :current_fields} do
      {:ok, %{store_id: store_id, epoch_id: epoch_id, manifest_digest: digest}}
    else
      {:ok, _} -> {:error, :current_format}
      error -> error
    end
  end

  def encode_manifest(manifest) do
    with :ok <- manifest?(manifest),
         {:ok, body} <- Value.encode(manifest_body(manifest)),
         true <- byte_size(body) <= 16_777_216 - 16 || {:error, :manifest_too_large} do
      {:ok, checked(<<"TAYM", 1, 0::24, byte_size(body)::32, body::binary>>)}
    end
  end

  def decode_manifest(bytes) when is_binary(bytes) and byte_size(bytes) <= 16_777_216 do
    with {:ok, <<"TAYM", 1, 0::24, length::32, body::binary>>} <-
           checked_body(bytes, :variable),
         true <- length == byte_size(body) || {:error, :manifest_length},
         {:ok, value} <- Value.decode(body),
         true <- exact?(value, @manifest_keys) || {:error, :manifest_keys},
         {:ok, manifest} <- manifest_from_body(value),
         :ok <- manifest?(manifest) do
      {:ok, manifest}
    else
      {:ok, _} -> {:error, :manifest_format}
      error -> error
    end
  end

  def decode_manifest(_), do: {:error, :manifest_format}

  def manifest_digest(bytes) when is_binary(bytes), do: :crypto.hash(:sha256, bytes)

  @doc "A durable first-adoption rollback intent; it names exactly one preserved V1 directory."
  def encode_adoption(nonce) do
    if V1.id?(nonce),
      do: {:ok, checked(<<"TAYA", 1, 0::24, nonce::binary>>)},
      else: {:error, :adoption_nonce}
  end

  def decode_adoption(bytes) do
    with {:ok, <<"TAYA", 1, 0::24, nonce::binary-size(16)>>} <- checked_body(bytes, 24),
         true <- V1.id?(nonce) || {:error, :adoption_nonce},
         do: {:ok, nonce},
         else: (
           {:ok, _} -> {:error, :adoption_format}
           error -> error
         )
  end

  def verify_selection(marker, current, manifest_bytes) do
    with {:ok, store_id} <- decode_marker(marker),
         {:ok, pointer} <- decode_current(current),
         {:ok, manifest} <- decode_manifest(manifest_bytes),
         true <- pointer.store_id == store_id || {:error, :store_id_mismatch},
         true <- manifest.store_id == store_id || {:error, :store_id_mismatch},
         true <- manifest.epoch_id == pointer.epoch_id || {:error, :epoch_mismatch},
         true <-
           manifest_digest(manifest_bytes) == pointer.manifest_digest ||
             {:error, :manifest_digest} do
      {:ok, manifest}
    end
  end

  def manifest?(
        %{
          store_id: store_id,
          epoch_id: epoch_id,
          source_epoch_id: source_epoch_id,
          source_frontier: frontier,
          captured_at: captured_at,
          terminal_retention: retention,
          source_segments: source,
          base_segments: base,
          tail_segment_id: tail_id,
          tail_first_sequence: tail_first
        } = manifest
      ) do
    cond do
      not exact?(manifest, Enum.map(@manifest_keys, &String.to_existing_atom/1)) ->
        {:error, :manifest_fields}

      not V1.id?(store_id) or not V1.id?(epoch_id) ->
        {:error, :manifest_id}

      not (is_nil(source_epoch_id) or V1.id?(source_epoch_id)) ->
        {:error, :source_epoch}

      not is_integer(frontier) or frontier not in 0..@max ->
        {:error, :source_frontier}

      not V1.time?(captured_at) ->
        {:error, :captured_at}

      Retention.validate(retention) != :ok ->
        {:error, :terminal_retention}

      not valid_source?(source) ->
        {:error, :source_segments}

      not valid_base?(base, tail_id, tail_first) ->
        {:error, :base_segments}

      true ->
        :ok
    end
  end

  def manifest?(_), do: {:error, :manifest_fields}

  defp valid_source?(source) when is_list(source) do
    Enum.with_index(source, 1)
    |> Enum.all?(fn {entry, id} ->
      exact?(entry, [:id, :digest]) and entry.id == id and digest?(entry.digest)
    end)
  end

  defp valid_source?(_), do: false

  defp valid_base?(base, tail_id, tail_first)
       when is_list(base) and is_integer(tail_id) and is_integer(tail_first) do
    {valid, next_sequence} =
      Enum.with_index(base, 1)
      |> Enum.reduce({true, 1}, fn {entry, id}, {valid, next_sequence} ->
        entry_valid =
          exact?(entry, [:id, :first_sequence, :last_sequence, :bytes, :digest]) and
            entry.id == id and entry.first_sequence == next_sequence and
            uint?(entry.last_sequence) and entry.last_sequence >= next_sequence and
            is_integer(entry.bytes) and entry.bytes in 64..1_073_741_824 and
            digest?(entry.digest)

        {valid and entry_valid, if(entry_valid, do: entry.last_sequence + 1, else: next_sequence)}
      end)

    valid and tail_id == length(base) + 1 and tail_first == next_sequence and
      tail_first in 1..@max
  end

  defp valid_base?(_, _, _), do: false

  defp manifest_body(m) do
    %{
      "store_id" => {:bytes, m.store_id},
      "epoch_id" => {:bytes, m.epoch_id},
      "source_epoch_id" => if(m.source_epoch_id, do: {:bytes, m.source_epoch_id}),
      "source_frontier" => m.source_frontier,
      "captured_at" => m.captured_at,
      "terminal_retention" => Retention.to_value(m.terminal_retention),
      "source_segments" =>
        Enum.map(m.source_segments, &%{"id" => &1.id, "digest" => {:bytes, &1.digest}}),
      "base_segments" =>
        Enum.map(m.base_segments, fn entry ->
          %{
            "id" => entry.id,
            "first_sequence" => entry.first_sequence,
            "last_sequence" => entry.last_sequence,
            "bytes" => entry.bytes,
            "digest" => {:bytes, entry.digest}
          }
        end),
      "tail_segment_id" => m.tail_segment_id,
      "tail_first_sequence" => m.tail_first_sequence
    }
  end

  defp manifest_from_body(body) do
    with {:ok, retention} <- Retention.from_value(body["terminal_retention"]),
         {:ok, source} <- entries(body["source_segments"], @source_keys, [:id, :digest]),
         {:ok, base} <-
           entries(body["base_segments"], @base_keys, [
             :id,
             :first_sequence,
             :last_sequence,
             :bytes,
             :digest
           ]) do
      {:ok,
       %{
         store_id: unbytes(body["store_id"]),
         epoch_id: unbytes(body["epoch_id"]),
         source_epoch_id: unbytes(body["source_epoch_id"]),
         source_frontier: body["source_frontier"],
         captured_at: body["captured_at"],
         terminal_retention: retention,
         source_segments: source,
         base_segments: base,
         tail_segment_id: body["tail_segment_id"],
         tail_first_sequence: body["tail_first_sequence"]
       }}
    end
  end

  defp entries(list, string_keys, atom_keys) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      if exact?(entry, string_keys) do
        decoded =
          Map.new(atom_keys, fn key ->
            value = entry[Atom.to_string(key)]
            {key, if(key == :digest, do: unbytes(value), else: value)}
          end)

        {:cont, {:ok, [decoded | acc]}}
      else
        {:halt, {:error, :manifest_entries}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp entries(_, _, _), do: {:error, :manifest_entries}

  defp unbytes({:bytes, bytes}), do: bytes
  defp unbytes(_), do: nil

  defp checked(body), do: <<body::binary, CRC32C.checksum(body)::32>>

  defp checked_body(bytes, size) when is_binary(bytes) do
    body_size = byte_size(bytes) - 4

    if body_size < 0 or (size != :variable and body_size != size) do
      {:error, :metadata_length}
    else
      <<body::binary-size(^body_size), checksum::32>> = bytes

      if CRC32C.checksum(body) == checksum,
        do: {:ok, body},
        else: {:error, :metadata_checksum}
    end
  end

  defp checked_body(_, _), do: {:error, :metadata_length}
  defp digest?(bytes), do: is_binary(bytes) and byte_size(bytes) == 32
  defp uint?(value), do: is_integer(value) and value in 1..@max

  defp exact?(map, keys),
    do: is_map(map) and not is_struct(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
end
