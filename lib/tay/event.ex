defmodule Tay.Event do
  @moduledoc """
  Production Event v1 semantic codec. The runtime Event struct is not serialized;
  only the approved six exact string-keyed payload schemas are encoded. State
  and registry-independent decoding implements the Phase 3 EventDecoder boundary.
  """
  @behaviour Tay.Storage.Recovery.EventDecoder
  alias Tay.Event.{Value, V1}
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
  def known_type?(type), do: is_integer(type) and type in 1..6
  @impl true
  def supported_schema?(type, schema), do: known_type?(type) and schema === 1

  def encode(event, limits \\ Value.defaults(), max_bytes \\ 16_777_216)

  def encode(
        %__MODULE__{record_type: type, payload_schema_version: schema, data: data},
        limits,
        max_bytes
      ) do
    with :ok <- capability(type, schema),
         true <- is_map(data) || {:error, :invalid_event},
         wire = Map.update(data, "job_id", nil, &{:bytes, &1}),
         {:ok, _} <- Value.measure(wire, limits, max_bytes),
         :ok <- V1.validate(type, data),
         {:ok, payload} <- Value.encode(wire, limits, max_bytes),
         do: {:ok, {type, schema, payload}}
  end

  def encode(_, _, _), do: {:error, :invalid_event}

  @impl true
  def decode_payload(type, schema, payload, limits) do
    with :ok <- capability(type, schema),
         {:ok, wire} <- Value.decode(payload, limits),
         %{"job_id" => {:bytes, id}} <- wire,
         data = Map.put(wire, "job_id", id),
         :ok <- V1.validate(type, data),
         do: {:ok, %__MODULE__{record_type: type, data: data}, byte_size(payload)},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_event}
         )
  end

  defp capability(type, schema) do
    cond do
      not known_type?(type) -> {:error, :unknown_event_type}
      not supported_schema?(type, schema) -> {:error, :unsupported_payload_schema}
      true -> :ok
    end
  end
end
