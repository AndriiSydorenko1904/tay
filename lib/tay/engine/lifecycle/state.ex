defmodule Tay.Engine.Lifecycle.State do
  @moduledoc false
  alias Tay.Engine.Lifecycle.CommandDelivery
  @enforce_keys [:table, :config, :root, :meta]
  defstruct [
    :table,
    :config,
    :root,
    :meta,
    :operation,
    :policy,
    :shutdown_waiter,
    :engine,
    :writer,
    :runtime,
    :fence,
    monitors: %{},
    permits: %{},
    memory_permits: %{},
    delivery: %CommandDelivery{}
  ]

  @type t :: %__MODULE__{}
end
