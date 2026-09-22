defmodule Tay.Dashboard.JobLive do
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @impl true
  def mount(%{"id" => id}, session, socket) do
    {:ok, socket |> Live.initialize(session) |> assign(id: id) |> refresh()}
  end

  @impl true
  def handle_event(action, _params, socket) when action in ["retry", "cancel"] do
    result =
      case {action, socket.assigns.job} do
        {_, nil} ->
          {:error, :not_found}

        {"retry", job} ->
          Tay.retry(job.id, name: socket.assigns.engine, expected_revision: job.revision)

        {"cancel", job} ->
          Tay.cancel(job.id, name: socket.assigns.engine, expected_revision: job.revision)
      end

    socket =
      case result do
        {:ok, job} -> assign(socket, job: job, flash_error: nil)
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
    <Live.shell current={:job} path={@dashboard_path}>
      <h2>Job details</h2>
      <div :if={@flash_error} class="error">{@flash_error}</div>
      <div :if={@job} id="job-details">
        <div class="actions">
          <button :if={@job.state in [:retryable, :discarded]} phx-click="retry">Retry</button>
          <button
            :if={@job.state in [:available, :scheduled, :retryable, :executing]}
            phx-click="cancel"
          >Cancel</button>
        </div>
        <table>
          <tbody>
            <tr>
              <th>ID</th><td>{@job.id}</td>
            </tr><tr>
              <th>Worker</th><td>{@job.worker_key}</td>
            </tr>
            <tr>
              <th>Queue</th><td>{@job.queue}</td>
            </tr><tr>
              <th>State</th><td><span class="badge">{@job.state}</span></td>
            </tr>
            <tr>
              <th>Attempt</th><td>{@job.attempt}/{@job.max_attempts}</td>
            </tr>
            <tr>
              <th>Inserted</th><td>{inspect(@job.inserted_at)}</td>
            </tr><tr>
              <th>Scheduled</th><td>{inspect(@job.scheduled_at)}</td>
            </tr>
            <tr>
              <th>Attempted</th><td>{inspect(@job.attempted_at)}</td>
            </tr><tr>
              <th>Completed</th><td>{inspect(@job.completed_at)}</td>
            </tr>
          </tbody>
        </table>
        <h3>Arguments</h3><pre>{safe_inspect(@job.args)}</pre>
        <h3>Last error</h3><pre>{safe_inspect(List.first(@job.errors))}</pre>
      </div>
    </Live.shell>
    """
  end

  defp refresh(socket) do
    case Tay.get_job(socket.assigns.id, name: socket.assigns.engine) do
      {:ok, job} -> assign(socket, job: job, flash_error: nil)
      {:error, error} -> assign(socket, job: nil, flash_error: Live.error_message(error))
    end
  end

  defp safe_inspect(value), do: inspect(value, pretty: true, limit: 50, printable_limit: 4_096)
end
