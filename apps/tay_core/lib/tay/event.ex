defmodule Tay.Event do
  @moduledoc """
  Production Event v2 semantic codec. Event-v1 types remain byte-for-byte
  compatible and are decoded through the V2 implementation. The runtime Event
  struct is not serialized; only approved exact string-keyed payload schemas are
  encoded. State- and registry-independent decoding implements the recovery
  EventDecoder boundary.
  """
  @behaviour Tay.Storage.Recovery.EventDecoder
  alias Tay.Event.{Value, V2}
  @enforce_keys [:record_type, :data]
  defstruct [:record_type, :data, payload_schema_version: 1]
  @on_load :check_runtime

  @doc false
  def check_runtime do
    if Enum.all?([0, 0x8000000000000000, 1, 0x7FEFFFFFFFFFFFFF], fn bits ->
         <<f::float-big-64>> = <<bits::64>>
         <<f::float-big-64>> == <<bits::64>>
       end), do: :ok, else: :error
  end

  @impl true
  def known_type?(type), do: is_integer(type) and V2.known_type?(type)
  @impl true
  def supported_schema?(type, schema), do: V2.supported_schema?(type, schema)

  def encode(event, limits \\ Value.defaults(), max_bytes \\ 16_777_216)

  def encode(
        %__MODULE__{record_type: type, payload_schema_version: schema, data: data},
        limits,
        max_bytes
      ) do
    with :ok <- capability(type, schema),
         true <- is_map(data) || {:error, :invalid_event},
         {:ok, wire} <- encode_identity(type, data),
         {:ok, _} <- Value.measure(wire, limits, max_bytes),
         :ok <- V2.validate(type, schema, data),
         {:ok, payload} <- Value.encode(wire, limits, max_bytes),
         do: {:ok, {type, schema, payload}}
  end

  def encode(_, _, _), do: {:error, :invalid_event}

  @impl true
  def decode_payload(type, schema, payload, limits) do
    with :ok <- capability(type, schema),
         {:ok, wire} <- Value.decode(payload, limits),
         {:ok, data} <- decode_identity(type, wire),
         :ok <- V2.validate(type, schema, data),
         do:
           {:ok, %__MODULE__{record_type: type, payload_schema_version: schema, data: data},
            byte_size(payload)}
  end

  defp capability(type, schema) do
    cond do
      not known_type?(type) -> {:error, :unknown_event_type}
      not supported_schema?(type, schema) -> {:error, :unsupported_payload_schema}
      true -> :ok
    end
  end

  defp encode_identity(type, data) do
    case V2.binary_identity_field(type) do
      nil ->
        {:ok, data}

      field ->
        case Map.fetch(data, field) do
          {:ok, id} -> {:ok, Map.put(data, field, {:bytes, id})}
          :error -> {:error, :invalid_event}
        end
    end
  end

  defp decode_identity(type, wire) when is_map(wire) and not is_struct(wire) do
    case V2.binary_identity_field(type) do
      nil ->
        {:ok, wire}

      field ->
        case Map.fetch(wire, field) do
          {:ok, {:bytes, id}} -> {:ok, Map.put(wire, field, id)}
          _ -> {:error, :invalid_event}
        end
    end
  end

  defp decode_identity(_type, _wire), do: {:error, :invalid_event}
end
