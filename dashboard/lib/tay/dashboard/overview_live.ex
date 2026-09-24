defmodule Tay.Dashboard.OverviewLive do
  @moduledoc false
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> Live.initialize(session)
     |> assign(
       confirm_compaction: false,
       compaction_result: nil,
       storage_bytes: 0,
       segment_count: 0,
       configured_retention: "Unknown",
       retention_hours: 24
     )
     |> refresh()}
  end

  @impl true
  def handle_event("prepare-compaction", _params, socket) do
    {:noreply, assign(socket, confirm_compaction: true, compaction_result: nil)}
  end

  def handle_event("cancel-compaction", _params, socket) do
    {:noreply, assign(socket, confirm_compaction: false)}
  end

  def handle_event("compact", %{"terminal_retention_hours" => value}, socket) do
    case Integer.parse(value) do
      {hours, ""} when hours > 0 ->
        compact(socket, hours)

      _ ->
        {:noreply, assign(socket, flash_error: "Retention must be a positive number of hours.")}
    end
  end

  def handle_event("compact", _params, socket) do
    compact(socket, socket.assigns.retention_hours)
  end

  defp compact(socket, retention_hours) do
    socket = assign(socket, confirm_compaction: false, compaction_result: nil)

    case Tay.compact(
           name: socket.assigns.engine,
           timeout: 900_000,
           terminal_retention: {:hours, retention_hours}
         ) do
      {:ok, stats} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(compaction_result: compacted(stats, retention_hours))}

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
        <div class="cards">
          <div class="card">
            <div>Canonical history</div>
            <div class="count">{format_mib(@storage_bytes)}</div>
          </div>
          <div class="card">
            <div>Segments</div>
            <div class="count">{@segment_count}</div>
          </div>
          <div class="card">
            <div>Configured retention</div>
            <div class="count">{@configured_retention}</div>
          </div>
        </div>
        <p style="color:var(--tay-muted)">
          Compaction rewrites the job store and permanently removes terminal jobs older than the selected retention period. Retention is time-based, not a disk quota. Canonical history excludes temporary compaction headroom and small metadata files.
        </p>
        <button :if={!@confirm_compaction} id="prepare-compaction" phx-click="prepare-compaction">
          Run compaction
        </button>
        <form
          :if={@confirm_compaction}
          id="compaction-confirmation"
          class="notice"
          phx-submit="compact"
        >
          <strong>Run compaction now?</strong>
          <p>Completed, cancelled, and discarded jobs older than this period cannot be recovered afterward.</p>
          <label for="terminal-retention-hours">Retain terminal jobs for</label>
          <div class="actions">
            <input
              id="terminal-retention-hours"
              name="terminal_retention_hours"
              type="number"
              min="1"
              required
              value={@retention_hours}
              style="width:7rem"
            />
            <span>hours</span>
          </div>
          <div class="actions">
            <button id="confirm-compaction" type="submit" phx-disable-with="Compacting…">
              Confirm compaction
            </button>
            <button class="secondary" type="button" phx-click="cancel-compaction">Cancel</button>
          </div>
        </form>
      </section>
    </Live.shell>
    """
  end

  defp refresh(socket) do
    case Tay.stats(name: socket.assigns.engine) do
      {:ok, stats} ->
        status = Tay.status(name: socket.assigns.engine)
        retention = Map.get(status, :compaction_terminal_retention, {:hours, 24})
        retention_hours = retention_hours(retention)

        assign(socket,
          stats: stats,
          storage_bytes: Map.get(status, :canonical_history_bytes, 0),
          segment_count: Map.get(status, :segment_count, 0),
          configured_retention: format_retention(retention),
          retention_hours: retention_hours,
          flash_error: nil
        )

      {:error, error} ->
        assign(socket, stats: %{}, flash_error: Live.error_message(error))
    end
  end

  defp compacted(stats, retention_hours) do
    expired = Map.get(stats, :expired_jobs, 0)
    retained = Map.get(stats, :retained_terminal_jobs, 0)
    reclaimed = Map.get(stats, :reclaimed_bytes, 0)

    "Compaction completed with #{retention_hours} h retention: removed #{expired} expired jobs, reclaimed #{format_bytes(reclaimed)}, and retained #{retained} terminal jobs."
  end

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KiB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_mib(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 2) <> " MiB"
  defp format_retention({:hours, hours}), do: "#{hours} h"
  defp format_retention(:infinity), do: "Forever"
  defp format_retention(_), do: "Unknown"
  defp retention_hours({:hours, hours}), do: hours
  defp retention_hours(_), do: 24
end
