defmodule Tay.Engine.Supervisor do
  @moduledoc false
  use Supervisor
  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  def init(config) do
    children = [
      {Tay.Engine.Lifecycle, config},
      %{
        id: Tay.Engine,
        start: {Tay.Engine, :start_link, [config]},
        restart: :temporary,
        shutdown: 30_000
      }
    ]

    # No component may restart beneath surviving indexes. Guardian failure
    # terminates this runtime group; Engine failure leaves a closed diagnosis.
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end
end
