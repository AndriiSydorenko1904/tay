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
       engine_available: false,
       engine_state: :unavailable,
       engine_phase: nil,
       refresh_timer: nil,
       beam_memory: %{total: 0, processes: 0, ets: 0, binary: 0},
       capacity: %{
         jobs: 0,
         max_jobs: 0,
         active_jobs: 0,
         terminal_jobs: 0,
         max_terminal_jobs: 0,
         bytes: 0,
         max_bytes: 0,
         nodes: 0,
         max_nodes: 0
       },
       storage_bytes: 0,
       segment_count: 0,
       configured_retention: "Unknown",
       retention_hours: 24,
       storage_segments: [],
       storage_segments_truncated: false
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
  def handle_info(:tay_dashboard_refresh, socket) do
    {:noreply, socket |> assign(refresh_timer: nil) |> refresh()}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns.refresh_timer, do: Process.cancel_timer(socket.assigns.refresh_timer)
    Live.terminate(socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Live.shell current={:overview} path={@dashboard_path}>
      <h2>Overview</h2>
      <div :if={@flash_error} class="error">{@flash_error}</div>
      <div :if={!@engine_available} id="engine-unavailable" class="notice">
        {lifecycle_message(@engine_state, @engine_phase)}
      </div>
      <div
        :if={@engine_state == :compacting && @engine_available}
        id="engine-compacting"
        class="notice"
      >
        {lifecycle_message(@engine_state, @engine_phase)}
      </div>
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
        <h3>Runtime memory</h3>
        <div class="cards">
          <div class="card">
            <div>BEAM total</div>
            <div class="count">{format_mib(@beam_memory.total)}</div>
          </div>
          <div class="card">
            <div>Processes</div>
            <div class="count">{format_mib(@beam_memory.processes)}</div>
          </div>
          <div class="card">
            <div>ETS</div>
            <div class="count">{format_mib(@beam_memory.ets)}</div>
          </div>
          <div class="card">
            <div>Binaries</div>
            <div class="count">{format_mib(@beam_memory.binary)}</div>
          </div>
        </div>
        <p style="color:var(--tay-muted)">
          BEAM total is the memory managed by the Erlang VM hosting Tay and this dashboard. ETS, processes, and binaries are components of that total; they must not be added together again.
        </p>
      </section>
      <section style="margin-top:28px">
        <h3>State capacity</h3>
        <div class="cards">
          <div class="card">
            <div>Active jobs</div>
            <div class="count">
              {available(@engine_available, format_ratio(@capacity.active_jobs, @capacity.max_jobs))}
            </div>
          </div>
          <div class="card">
            <div>Terminal history</div>
            <div class="count">
              {available(
                @engine_available,
                format_ratio(@capacity.terminal_jobs, @capacity.max_terminal_jobs)
              )}
            </div>
          </div>
          <div class="card">
            <div>Charged state</div>
            <div class="count">
              {available(
                @engine_available,
                "#{format_bytes(@capacity.bytes)} / #{format_bytes(@capacity.max_bytes)}"
              )}
            </div>
          </div>
          <div class="card">
            <div>Retained nodes</div>
            <div class="count">
              {available(@engine_available, format_ratio(@capacity.nodes, @capacity.max_nodes))}
            </div>
          </div>
        </div>
        <p style="color:var(--tay-muted)">
          State capacity is conservative admission accounting, not measured RAM. New jobs are rejected before any configured budget is exceeded.
        </p>
      </section>
      <section style="margin-top:28px">
        <h3>Storage maintenance</h3>
        <div class="cards">
          <div class="card">
            <div>Canonical history</div>
            <div class="count">{available(@engine_available, format_mib(@storage_bytes))}</div>
          </div>
          <div class="card">
            <div>Segments</div>
            <div class="count">{available(@engine_available, @segment_count)}</div>
          </div>
          <div class="card">
            <div>Configured retention</div>
            <div class="count">{available(@engine_available, @configured_retention)}</div>
          </div>
        </div>
        <p style="color:var(--tay-muted)">
          Compaction rewrites the job store and permanently removes terminal jobs older than the selected retention period. Retention is time-based, not a disk quota. Canonical history excludes temporary compaction headroom and small metadata files.
        </p>
        <details :if={@storage_segments != []} id="storage-segments">
          <summary>Storage segments ({length(@storage_segments)} shown)</summary>
          <p :if={@storage_segments_truncated} class="notice">
            Only the 128 newest segments are shown; the total is {@segment_count}.
          </p>
          <table>
            <thead>
              <tr>
                <th>FILE</th>
                <th>STATE</th>
                <th>SIZE</th>
                <th>RECORDS</th>
                <th>SEQUENCE</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={segment <- @storage_segments}>
                <td><code>{segment_filename(segment.id)}</code></td>
                <td><span class={["state", "state-#{segment.state}"]}>{segment.state}</span></td>
                <td>{format_bytes(segment.bytes)}</td>
                <td>{segment.count}</td>
                <td>{sequence_range(segment)}</td>
              </tr>
            </tbody>
          </table>
        </details>
        <button
          :if={!@confirm_compaction && @engine_available}
          id="prepare-compaction"
          phx-click="prepare-compaction"
        >
          Run compaction
        </button>
        <form
          :if={@confirm_compaction}
          id="compaction-confirmation"
          class="notice"
          phx-submit="compact"
        >
          <strong>Run compaction now?</strong>
          <p>
            Completed, cancelled, and discarded jobs older than this period cannot be recovered afterward.
          </p>
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
    status = Tay.status(name: socket.assigns.engine)
    memory = Map.new(:erlang.memory())

    case Tay.stats(name: socket.assigns.engine) do
      {:ok, stats} ->
        retention = Map.get(status, :compaction_terminal_retention, {:hours, 24})
        retention_hours = retention_hours(retention)

        if socket.assigns.refresh_timer, do: Process.cancel_timer(socket.assigns.refresh_timer)

        assign(socket,
          stats: stats,
          engine_available: true,
          engine_state: Map.get(status, :state, :ready),
          engine_phase: Map.get(status, :phase),
          refresh_timer: nil,
          beam_memory: %{
            total: Map.get(memory, :total, 0),
            processes: Map.get(memory, :processes, 0),
            ets: Map.get(memory, :ets, 0),
            binary: Map.get(memory, :binary, 0)
          },
          capacity: %{
            jobs: Map.get(status, :jobs, 0),
            max_jobs: Map.get(status, :max_jobs, 0),
            active_jobs: Map.get(status, :active_jobs, 0),
            terminal_jobs: Map.get(status, :terminal_jobs, terminal_count(stats)),
            max_terminal_jobs: Map.get(status, :max_terminal_jobs, 0),
            bytes: Map.get(status, :active_state_bytes_charged, 0),
            max_bytes: Map.get(status, :max_state_bytes, 0),
            nodes: Map.get(status, :active_state_nodes_charged, 0),
            max_nodes: Map.get(status, :max_state_nodes, 0)
          },
          storage_bytes: Map.get(status, :canonical_history_bytes, 0),
          segment_count: Map.get(status, :segment_count, 0),
          configured_retention: format_retention(retention),
          retention_hours: retention_hours,
          storage_segments: Map.get(status, :storage_segments, []),
          storage_segments_truncated: Map.get(status, :storage_segments_truncated, false),
          flash_error: nil
        )

      {:error, error} ->
        timer =
          if Phoenix.LiveView.connected?(socket) and is_nil(socket.assigns.refresh_timer),
            do: Process.send_after(self(), :tay_dashboard_refresh, 500),
            else: socket.assigns.refresh_timer

        assign(socket,
          stats: %{},
          engine_available: false,
          engine_state: Map.get(status, :state, :unavailable),
          engine_phase: Map.get(status, :phase),
          refresh_timer: timer,
          beam_memory: %{
            total: Map.get(memory, :total, 0),
            processes: Map.get(memory, :processes, 0),
            ets: Map.get(memory, :ets, 0),
            binary: Map.get(memory, :binary, 0)
          },
          flash_error: lifecycle_error(status, error)
        )
    end
  end

  defp available(true, value), do: value
  defp available(false, _value), do: "—"

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
  defp format_ratio(value, limit), do: "#{format_integer(value)} / #{format_integer(limit)}"
  defp format_integer(value), do: value |> Integer.to_string() |> group_digits()
  defp group_digits(value) when byte_size(value) <= 3, do: value

  defp group_digits(value) do
    {head, tail} = String.split_at(value, rem(byte_size(value), 3))
    groups = tail |> String.graphemes() |> Enum.chunk_every(3) |> Enum.map_join(",", &Enum.join/1)
    if head == "", do: groups, else: head <> "," <> groups
  end

  defp format_retention({:hours, hours}), do: "#{hours} h"
  defp format_retention({:minutes, minutes}), do: "#{minutes} m"
  defp format_retention(:infinity), do: "Forever"
  defp format_retention(_), do: "Unknown"
  defp retention_hours({:hours, hours}), do: hours
  defp retention_hours({:minutes, minutes}), do: max(div(minutes + 59, 60), 1)
  defp retention_hours(_), do: 24

  defp lifecycle_message(:compacting, :preparing),
    do: "Engine state: compacting (preparing). Jobs continue to be accepted and executed."

  defp lifecycle_message(:compacting, :switching),
    do:
      "Engine state: compacting (switching). A validated atomic epoch switch is in progress; admission resumes automatically."

  defp lifecycle_message(:migrating, _),
    do:
      "Engine state: migrating. The one-time Store-v1 migration is draining and will recover automatically."

  defp lifecycle_message(state, phase) do
    suffix = if phase, do: " (#{phase})", else: ""

    "Engine state: #{state}#{suffix}. Capacity and storage values are unavailable until recovery completes."
  end

  defp lifecycle_error(%{state: state}, _error) when state in [:compacting, :migrating], do: nil
  defp lifecycle_error(_status, error), do: Live.error_message(error)

  defp terminal_count(stats),
    do: Enum.sum(for state <- [:completed, :cancelled, :discarded], do: Map.get(stats, state, 0))

  defp segment_filename(id),
    do: id |> Integer.to_string() |> String.pad_leading(20, "0") |> Kernel.<>(".tay")

  defp sequence_range(%{count: 0}), do: "—"

  defp sequence_range(segment),
    do: "#{segment.first_sequence}–#{segment.last_sequence}"
end
