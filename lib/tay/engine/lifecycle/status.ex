defmodule Tay.Engine.Lifecycle.Status do
  @moduledoc false

  # A completed or deferred administrative operation cannot retain its phase.
  def transition(status, state),
    do: status |> Map.drop([:phase, :reason]) |> Map.put(:state, state)
end
