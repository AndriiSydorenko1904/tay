defmodule Tay.Supervisor do
  @moduledoc """
  The empty root supervisor for Tay's Phase 0 application.

  `Tay.Application` validates configuration before starting this supervisor.
  No storage, state, scheduling, or execution children exist yet. Their future
  startup and restart dependencies are outside the Phase 0 scope.
  """

  use Supervisor

  @doc "Starts the root supervisor registered as `Tay.Supervisor`."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(args \\ []) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
