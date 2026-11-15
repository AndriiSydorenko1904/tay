defmodule Tay.Standalone.RuntimeMonitor do
  @moduledoc false
  use GenServer
  require Logger

  @check_interval_ms 1_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      significant: true
    }
  end

  @impl true
  def init(options) do
    send(self(), :check)
    {:ok, Keyword.get(options, :engine, Tay.Engine)}
  end

  @impl true
  def handle_info(:check, engine) do
    case Tay.status(name: engine) do
      %{state: :failed} ->
        Logger.error("Tay standalone is shutting down after execution generation failure")
        {:stop, {:shutdown, :engine_failed}, engine}

      _ ->
        Process.send_after(self(), :check, @check_interval_ms)
        {:noreply, engine}
    end
  end
end
