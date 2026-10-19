defmodule Tay.Executor.Protocol do
  @moduledoc false

  alias Tay.Protocol.V1, as: Codec

  defdelegate version(), to: Codec
  defdelegate default_max_frame_bytes(), to: Codec
  defdelegate frame(message), to: Codec
  defdelegate frame(message, max_frame_bytes), to: Codec
  defdelegate decode_frames(buffer), to: Codec
  defdelegate decode_frames(buffer, max_frame_bytes), to: Codec
  defdelegate decode_message(bytes), to: Codec
  defdelegate decode_message(bytes, max_frame_bytes), to: Codec
  defdelegate envelope(message), to: Codec
  defdelegate request_id(message), to: Codec
  defdelegate identifier?(value), to: Codec
  defdelegate task_key?(value), to: Codec
  defdelegate error(request_id, code), to: Codec
  defdelegate error(request_id, code, fields), to: Codec
  defdelegate reply(type, request_id), to: Codec
  defdelegate reply(type, request_id, fields), to: Codec
  defdelegate json_bytes(value, max_bytes), to: Codec
  defdelegate json_value?(value), to: Codec
  defdelegate json_value?(value, limits), to: Codec
end
