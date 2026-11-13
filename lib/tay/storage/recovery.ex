defmodule Tay.Storage.Recovery do
  @moduledoc false

  alias __MODULE__.Error

  @defaults %{
    deadline_ms: 900_000
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

  defp valid_option?({_, n}), do: is_integer(n) and n > 0
  defp invalid_options, do: {:error, Error.new(:argument, :invalid_recovery_options, :validation)}

  @doc false
  def check_deadline(native) do
    if is_integer(native.deadline) and System.monotonic_time(:millisecond) >= native.deadline,
      do: {:error, Error.new(:resource_limit, :deadline, :replay)},
      else: :ok
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
