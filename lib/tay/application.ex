defmodule Tay.Application do
  @moduledoc """
  Starts Tay's Phase 0 supervision foundation.

  Configuration is validated before the empty `Tay.Supervisor` is started.
  No storage directories are created and no workers are dispatched.
  The lifecycle dependencies of future engine components remain undefined.
  """

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, _config} <- Tay.Config.load() do
      Tay.Supervisor.start_link([])
    end
  end
end
