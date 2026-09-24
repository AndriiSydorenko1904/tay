defmodule Tay.Dashboard.OverviewLive do
  @moduledoc false
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> Live.initialize(session)
     |> assign(confirm_compaction: false, compaction_result: nil)
     |> refresh()}
  end

  @impl true
  def handle_event("prepare-compaction", _params, socket) do
    {:noreply, assign(socket, confirm_compaction: true, compaction_result: nil)}
  end

  def handle_event("cancel-compaction", _params, socket) do
    {:noreply, assign(socket, confirm_compaction: false)}
  end

  def handle_event("compact", _params, socket) do
    socket = assign(socket, confirm_compaction: false, compaction_result: nil)

    case Tay.compact(name: socket.assigns.engine, timeout: 900_000) do
      {:ok, stats} ->
        {:noreply, socket |> refresh() |> assign(compaction_result: compacted(stats))}

      {:error, error} ->
        {:noreply, assign(socket, flash_error: Live.error_message(error))}
    end
  end

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
      <div :if={@compaction_result} id="compaction-result" class="notice">
        {@compaction_result}
      </div>
      <div class="cards">
        <div :for={{state, count} <- @stats} class={["card", "state-#{state}"]}>
          <div>{state |> Atom.to_string() |> String.capitalize()}</div>
          <div class="count">{count}</div>
        </div>
      </div>
      <section style="margin-top:28px">
        <h3>Storage maintenance</h3>
        <p style="color:var(--tay-muted)">
          Compaction rewrites the job store and permanently removes terminal jobs older than the configured retention period.
        </p>
        <button :if={!@confirm_compaction} id="prepare-compaction" phx-click="prepare-compaction">
          Run compaction
        </button>
        <div :if={@confirm_compaction} id="compaction-confirmation" class="notice">
          <strong>Run compaction now?</strong>
          <p>Expired completed, cancelled, and discarded jobs cannot be recovered afterward.</p>
          <div class="actions">
            <button id="confirm-compaction" phx-click="compact" phx-disable-with="Compacting…">
              Confirm compaction
            </button>
            <button class="secondary" phx-click="cancel-compaction">Cancel</button>
          </div>
        </div>
      </section>
    </Live.shell>
    """
  end

  defp refresh(socket) do
    case Tay.stats(name: socket.assigns.engine) do
      {:ok, stats} -> assign(socket, stats: stats, flash_error: nil)
      {:error, error} -> assign(socket, stats: %{}, flash_error: Live.error_message(error))
    end
  end

  defp compacted(stats) do
    expired = Map.get(stats, :expired_jobs, 0)
    retained = Map.get(stats, :retained_terminal_jobs, 0)
    reclaimed = Map.get(stats, :reclaimed_bytes, 0)

    "Compaction completed: removed #{expired} expired jobs, reclaimed #{format_bytes(reclaimed)}, and retained #{retained} terminal jobs."
  end

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KiB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
end
