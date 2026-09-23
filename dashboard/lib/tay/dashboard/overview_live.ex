defmodule Tay.Dashboard.OverviewLive do
  @moduledoc false
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @impl true
  def mount(_params, session, socket), do: {:ok, socket |> Live.initialize(session) |> refresh()}

  @impl true
  def handle_info(:tay_dashboard_refresh, socket), do: {:noreply, refresh(socket)}

  @impl true
  def terminate(_reason, socket), do: Live.terminate(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Live.shell current={:overview} path={@dashboard_path}>
      <h2>Overview</h2>
      <div :if={@flash_error} class="error">{@flash_error}</div>
      <div class="cards">
        <div :for={{state, count} <- @stats} class="card">
          <div>{state |> Atom.to_string() |> String.capitalize()}</div>
          <div class="count">{count}</div>
        </div>
      </div>
    </Live.shell>
    """
  end

  defp refresh(socket) do
    case Tay.stats(name: socket.assigns.engine) do
      {:ok, stats} -> assign(socket, stats: stats, flash_error: nil)
      {:error, error} -> assign(socket, stats: %{}, flash_error: Live.error_message(error))
    end
  end
end
