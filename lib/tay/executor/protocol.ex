defmodule Tay.Executor.Protocol do
  @moduledoc """
  Small, transport-neutral codec for the public Executor Protocol v1.

  The durable Event codec is deliberately not used here.  Executor peers speak
  length-prefixed UTF-8 JSON so a non-BEAM runtime never has to understand ETF
  or Tay's on-disk value representation.
  """

  @version 1
  @default_max_frame_bytes 1_048_576
  @default_max_depth 32
  @default_max_nodes 10_000
  @types MapSet.new(~w(
    hello
    register_tasks
    unregister_tasks
    enqueue
    status
    result
    cancel
    started
    succeeded
    failed
    heartbeat
  ))

  @type message :: %{required(binary()) => term()}

  def version, do: @version
  def default_max_frame_bytes, do: @default_max_frame_bytes

  @doc "Encodes one JSON message with an unsigned 32-bit big-endian length prefix."
  def frame(message, max_frame_bytes \\ @default_max_frame_bytes) do
    with :ok <- valid_frame_limit(max_frame_bytes),
         true <- json_value?(message) || {:error, :invalid_json_value},
         {:ok, bytes} <- json_bytes(message, max_frame_bytes),
         true <- byte_size(bytes) > 0 || {:error, :empty_frame} do
      {:ok, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>}
    else
      false -> {:error, :invalid_frame}
      {:error, _} = error -> error
    end
  end

  @doc "Decodes all complete frames in a byte buffer, retaining an incomplete tail."
  def decode_frames(buffer, max_frame_bytes \\ @default_max_frame_bytes)

  def decode_frames(buffer, max_frame_bytes)
      when is_binary(buffer) and is_integer(max_frame_bytes) do
    with :ok <- valid_frame_limit(max_frame_bytes),
         do: decode_frames(buffer, max_frame_bytes, [])
  end

  def decode_frames(_, _), do: {:error, :invalid_frame_limit}

  defp decode_frames(buffer, _max_frame_bytes, acc) when byte_size(buffer) < 4,
    do: {:ok, Enum.reverse(acc), buffer}

  defp decode_frames(<<size::unsigned-big-32, rest::binary>>, max_frame_bytes, acc) do
    cond do
      size == 0 ->
        {:error, :empty_frame}

      size > max_frame_bytes ->
        {:error, :frame_too_large}

      byte_size(rest) < size ->
        {:ok, Enum.reverse(acc), <<size::unsigned-big-32, rest::binary>>}

      true ->
        <<payload::binary-size(size), tail::binary>> = rest

        with {:ok, message} <- decode_message(payload, max_frame_bytes) do
          decode_frames(tail, max_frame_bytes, [message | acc])
        end
    end
  end

  @doc "Decodes and validates a single JSON protocol envelope."
  def decode_message(bytes, max_frame_bytes \\ @default_max_frame_bytes)

  def decode_message(bytes, max_frame_bytes)
      when is_binary(bytes) and is_integer(max_frame_bytes) do
    with :ok <- valid_frame_limit(max_frame_bytes),
         true <- byte_size(bytes) in 1..max_frame_bytes || {:error, :frame_too_large},
         {:ok, value} <- decode_json(bytes),
         true <- json_value?(value) || {:error, :invalid_json_value},
         {:ok, message} <- envelope(value) do
      {:ok, message}
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
    end
  end

  def decode_message(_, _), do: {:error, :invalid_message}

  @doc "Validates the common `version`, `type`, and `request_id` envelope fields."
  def envelope(message) when is_map(message) and not is_struct(message) do
    version = Map.get(message, "version", Map.get(message, "v"))

    with true <- version == @version || {:error, :unsupported_version},
         true <- not (Map.has_key?(message, "version") and Map.has_key?(message, "v")) or
                   Map.fetch!(message, "version") == Map.fetch!(message, "v") ||
                   {:error, :invalid_version},
         type when is_binary(type) <- Map.get(message, "type") || {:error, :invalid_type},
         true <- MapSet.member?(@types, type) || {:error, :unknown_message},
         request_id when is_binary(request_id) <-
           Map.get(message, "request_id") || {:error, :invalid_request_id},
         true <- identifier?(request_id) || {:error, :invalid_request_id} do
      {:ok, Map.put(message, "version", @version) |> Map.delete("v")}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_envelope}
    end
  end

  def envelope(_), do: {:error, :invalid_envelope}

  def request_id(%{"request_id" => request_id}) when is_binary(request_id), do: request_id
  def request_id(_), do: nil

  def identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  def task_key?(value) do
    Tay.Event.V1.key?(value)
  end

  def error(request_id, code) when is_binary(code) do
    message = %{
      "version" => @version,
      "type" => "error",
      "error" => %{"code" => code}
    }

    if is_binary(request_id) and identifier?(request_id),
      do: Map.put(message, "request_id", request_id),
      else: message
  end

  def reply(type, request_id, fields \\ %{}) when is_binary(type) and is_map(fields) do
    %{"version" => @version, "type" => type, "request_id" => request_id}
    |> Map.merge(fields)
  end

  @doc "Encodes one JSON-safe value and verifies its independent byte budget."
  def json_bytes(value, max_bytes) when is_integer(max_bytes) and max_bytes >= 1 do
    try do
      bytes = value |> :json.encode() |> IO.iodata_to_binary()

      if byte_size(bytes) <= max_bytes,
        do: {:ok, bytes},
        else: {:error, :json_too_large}
    rescue
      _ -> {:error, :invalid_json_value}
    catch
      _, _ -> {:error, :invalid_json_value}
    end
  end

  def json_bytes(_, _), do: {:error, :invalid_json_value}

  @doc "Validates portable JSON values without admitting arbitrary BEAM terms."
  def json_value?(value, limits \\ %{depth: @default_max_depth, nodes: @default_max_nodes}) do
    with %{depth: depth, nodes: nodes} <- limits,
         true <- is_integer(depth) and depth in 1..128,
         true <- is_integer(nodes) and nodes in 1..1_000_000 do
      try do
        {_remaining, _} = validate_value(value, depth, nodes)
        true
      catch
        :throw, :invalid_json_value -> false
      end
    else
      _ -> false
    end
  end

  defp validate_value(_, _depth, 0), do: throw(:invalid_json_value)
  defp validate_value(_, 0, _nodes), do: throw(:invalid_json_value)

  defp validate_value(value, _depth, nodes) when value in [nil, false, true, :null],
    do: {nodes - 1, :scalar}

  defp validate_value(value, _depth, nodes) when is_integer(value), do: {nodes - 1, :scalar}

  defp validate_value(value, _depth, nodes) when is_float(value) do
    # The standard JSON encoder rejects non-finite BEAM floats.  Keeping the
    # check here makes the accepted public value domain explicit as well.
    if value == value, do: {nodes - 1, :scalar}, else: throw(:invalid_json_value)
  end

  defp validate_value(value, _depth, nodes) when is_binary(value) do
    if String.valid?(value), do: {nodes - 1, :scalar}, else: throw(:invalid_json_value)
  end

  defp validate_value(value, depth, nodes) when is_list(value) do
    Enum.reduce(value, {nodes - 1, :list}, fn child, {remaining, _} ->
      validate_value(child, depth - 1, remaining)
    end)
  end

  defp validate_value(value, depth, nodes) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, {nodes - 1, :map}, fn {key, child}, {remaining, _} ->
      if not (is_binary(key) and String.valid?(key) and byte_size(key) <= 4_096),
        do: throw(:invalid_json_value)

      validate_value(child, depth - 1, remaining)
    end)
  end

  defp validate_value(_, _depth, _nodes), do: throw(:invalid_json_value)

  defp decode_json(bytes) do
    try do
      case :json.decode(bytes) do
        value -> {:ok, value}
      end
    rescue
      _ -> {:error, :malformed_json}
    catch
      _, _ -> {:error, :malformed_json}
    end
  end

  defp valid_frame_limit(limit) when is_integer(limit) and limit in 1..16_777_216, do: :ok
  defp valid_frame_limit(_), do: {:error, :invalid_frame_limit}
end
