defmodule Tay.Engine.Lifecycle.Operation do
  @moduledoc false
  @enforce_keys [:token, :kind, :owner, :deadline, :phase, :cancel_flag]
  defstruct [
    :token,
    :kind,
    :owner,
    :deadline,
    :phase,
    :cancel_flag,
    :force,
    :from,
    :timer,
    :driver,
    :monitor,
    :stats,
    :terminal_retention,
    :expected_source
  ]

  @type t :: %__MODULE__{}
end
