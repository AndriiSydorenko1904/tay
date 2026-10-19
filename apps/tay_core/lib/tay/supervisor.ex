defmodule Tay.Supervisor do
  @moduledoc """
  The deliberately empty root supervisor for Tay's application.

  `Tay.Application` validates configuration before starting this supervisor.
  It never owns storage, state, scheduling or execution children. A consuming
  application explicitly supervises each Engine through `Tay.child_spec/1`.
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
