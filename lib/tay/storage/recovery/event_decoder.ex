defmodule Tay.Storage.Recovery.EventDecoder do
  @moduledoc """
  Explicit semantic capability boundary for recovery, not a physical Record codec.

  Providers are trusted, explicitly configured modules. They must stay fixed for
  an attempt, decode into inert values, enforce budgets during decoding, and
  report exact payload consumption. No worker resolution, atom creation, fallback,
  external side effect or implicit support is permitted. `Tay.Event` supplies
  the separately approved production Event v1 implementation; this behaviour
  does not itself assign types, schemas or payload bytes.
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
