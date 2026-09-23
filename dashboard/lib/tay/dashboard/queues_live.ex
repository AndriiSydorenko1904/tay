defmodule Tay.Dashboard.QueuesLive do
  @moduledoc false
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @impl true
  def mount(_params, session, socket), do: {:ok, socket |> Live.initialize(session) |> refresh()}

  @impl true
  def handle_event(action, %{"queue" => queue}, socket) when action in ["pause", "resume"] do
    result =
      if action == "pause",
        do: Tay.pause_queue(queue, name: socket.assigns.engine),
        else: Tay.resume_queue(queue, name: socket.assigns.engine)

    socket =
      case result do
        :ok -> refresh(socket)
        {:error, error} -> assign(refresh(socket), flash_error: Live.error_message(error))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tay_dashboard_refresh, socket), do: {:noreply, refresh(socket)}

  @impl true
  def terminate(_reason, socket), do: Live.terminate(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Live.shell current={:queues} path={@dashboard_path}>
      <h2>Queues</h2>
      <div :if={@flash_error} class="error">{@flash_error}</div>
      <table>
        <thead>
          <tr>
            <th>Queue</th><th>Status</th><th>Concurrency</th><th>Executing</th><th>Jobs</th><th></th>
          </tr>
        </thead>
        <tbody id="queues">
          <tr :for={queue <- @queues} id={"queue-#{queue.key}"}>
            <td>{queue.key}</td><td>
              <span class="badge">{if queue.paused, do: "paused", else: "running"}</span>
            </td>
            <td>{queue.concurrency}</td><td>{queue.executing}</td><td>{queue.jobs}</td>
            <td>
              <button
                phx-click={if queue.paused, do: "resume", else: "pause"}
                phx-value-queue={queue.key}
              >{if queue.paused, do: "Resume", else: "Pause"}</button>
            </td>
          </tr>
        </tbody>
      </table>
    </Live.shell>
    """
  end

  defp refresh(socket) do
    case Tay.queues(name: socket.assigns.engine) do
      {:ok, queues} -> assign(socket, queues: queues, flash_error: nil)
      {:error, error} -> assign(socket, queues: [], flash_error: Live.error_message(error))
    end
  end
end
