defmodule Tay.Application do
  @moduledoc """
  Starts Tay's storage-free supervision foundation.

  Configuration is validated before the empty `Tay.Supervisor` is started.
  No storage directories are created and no workers are dispatched.
  Production startup requires an explicitly configured data directory. Physical
  storage sessions are started explicitly; engine recovery wiring is deferred.
  """

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, config} <- Tay.Config.load(),
         :ok <- Tay.Config.validate_startup(config) do
      Tay.Supervisor.start_link([])
    end
  end
end
