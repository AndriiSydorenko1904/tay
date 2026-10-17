defmodule Tay.Storage.Recovery do
  @moduledoc false

  alias __MODULE__.Error

  @max_decode_payload_bytes_limit 16_777_216
  @max_directory_entries_limit 4_294_967_295

  @defaults %{
    max_decode_payload_bytes: @max_decode_payload_bytes_limit,
    max_directory_entries: 100_000,
    max_total_segment_bytes: :infinity,
    max_replay_records: :infinity,
    deadline_ms: 900_000,
    activation_window_ms: 30_000,
    activation_deadline_ms: 900_000,
    io_timeout_ms: 10_000,
    event_limits: %{
      depth: 64,
      output_nodes: 100_000,
      binary_bytes: @max_decode_payload_bytes_limit
    }
  }

  @doc false
  def options(options) do
    if Keyword.keyword?(options) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &Map.has_key?(@defaults, &1)) do
      opts = Map.merge(@defaults, Map.new(options))
      if Enum.all?(opts, &valid_option?/1), do: {:ok, opts}, else: invalid_options()
    else
      invalid_options()
    end
  end

  defp valid_option?({:max_decode_payload_bytes, n}),
    do: is_integer(n) and n in 0..@max_decode_payload_bytes_limit

  defp valid_option?({:max_directory_entries, n}),
    do: is_integer(n) and n in 1..@max_directory_entries_limit

  defp valid_option?({:max_total_segment_bytes, n}),
    do: n == :infinity or (is_integer(n) and n > 0)

  defp valid_option?({:max_replay_records, n}), do: n == :infinity or (is_integer(n) and n >= 0)

  defp valid_option?({:event_limits, limits}) do
    is_map(limits) and map_size(limits) == 3 and
      Enum.all?([:depth, :output_nodes], &(is_integer(limits[&1]) and limits[&1] > 0)) and
      is_integer(limits[:binary_bytes]) and limits.binary_bytes >= 0
  end

  defp valid_option?({_, n}), do: is_integer(n) and n > 0
  defp invalid_options, do: {:error, Error.new(:argument, :invalid_recovery_options, :validation)}

  @doc false
  def check_deadline(native) do
    if is_integer(native.deadline) and System.monotonic_time(:millisecond) >= native.deadline,
      do: {:error, Error.new(:resource_limit, :deadline, :replay)},
      else: :ok
  end

  @doc false
  def budget(actual, limit, key, stage) do
    if limit == :infinity or actual <= limit,
      do: :ok,
      else: {:error, Error.new(:resource_limit, {key, actual, limit}, stage)}
  end

  @doc false
  def provider(codec, reducer) do
    if is_atom(codec) and codec not in [nil, false, true] and is_function(reducer, 3) and
         Code.ensure_loaded?(codec) and
         Enum.all?(
           [known_type?: 1, supported_schema?: 2, decode_payload: 4],
           fn {fun, arity} -> function_exported?(codec, fun, arity) end
         ) do
      {:ok, {codec, codec.module_info(:md5)}}
    else
      {:error, Error.new(:argument, :explicit_event_decoder_required, :validation)}
    end
  end
end
