defmodule Tay.Storage.BufferedRead do
  @moduledoc false

  @default_chunk_bytes 1_048_576

  def with_reader(source, size, fun, options \\ [])
      when is_function(source, 2) and is_integer(size) and size >= 0 and is_function(fun, 1) do
    chunk_bytes = Keyword.get(options, :chunk_bytes, @default_chunk_bytes)
    invalid_range = Keyword.get(options, :invalid_range, :invalid_read_range)
    short_read = Keyword.get(options, :short_read, :short_read)

    if is_integer(chunk_bytes) and chunk_bytes > 0 do
      cache = {__MODULE__, make_ref()}

      try do
        fun.(fn offset, length ->
          read(source, cache, size, chunk_bytes, invalid_range, short_read, offset, length)
        end)
      after
        Process.delete(cache)
      end
    else
      {:error, :invalid_read_buffer_size}
    end
  end

  defp read(_source, _cache, _size, _chunk, _invalid, _short, _offset, 0),
    do: {:ok, <<>>}

  defp read(source, cache, size, chunk, _invalid, short, offset, length)
       when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0 and
              offset + length <= size do
    case cached_slice(Process.get(cache), offset, length) do
      {:ok, bytes} ->
        {:ok, bytes}

      :miss when length > chunk ->
        exact_read(source, offset, length, short)

      :miss ->
        read_length = min(chunk, size - offset)

        with {:ok, bytes} <- exact_read(source, offset, read_length, short) do
          Process.put(cache, {offset, bytes})
          {:ok, binary_part(bytes, 0, length)}
        end
    end
  end

  defp read(_source, _cache, _size, _chunk, invalid, _short, _offset, _length),
    do: {:error, invalid}

  defp cached_slice({cache_offset, bytes}, offset, length)
       when offset >= cache_offset and offset + length <= cache_offset + byte_size(bytes) do
    {:ok, binary_part(bytes, offset - cache_offset, length)}
  end

  defp cached_slice(_, _, _), do: :miss

  defp exact_read(source, offset, length, short) do
    case source.(offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _} -> {:error, short}
      error -> error
    end
  end
end
