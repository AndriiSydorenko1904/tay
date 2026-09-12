defmodule Tay.Storage.Recovery.EventDecoder do
  @moduledoc """
  Explicit semantic capability boundary for recovery, not a production encoding.

  Providers are trusted, explicitly configured modules. They must stay fixed for
  an attempt, decode into inert values, enforce budgets during decoding, and
  report exact payload consumption. No worker resolution, atom creation, fallback,
  external side effect or implicit support is permitted. Production meanings and
  serialization require their own RFC; Phase 3 supplies only this behaviour.
  """
  @type limits :: %{
          depth: pos_integer(),
          output_nodes: pos_integer(),
          binary_bytes: non_neg_integer()
        }
  @callback known_type?(1..254) :: boolean()
  @callback supported_schema?(1..254, 1..255) :: boolean()
  @callback decode_payload(1..254, 1..255, binary(), limits()) ::
              {:ok, term(), non_neg_integer()} | {:error, term()}
end
