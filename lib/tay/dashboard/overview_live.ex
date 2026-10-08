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
       compaction_running: false,
       compaction_ref: nil,
       compaction_result: nil,
       engine_available: false,
       engine_state: :unavailable,
       engine_phase: nil,
       refresh_timer: nil,
       beam_memory: %{total: 0, processes: 0, ets: 0, binary: 0},
       capacity: %{
         jobs: 0,
         active_jobs: 0,
         terminal_jobs: 0,
         bytes: 0,
         max_bytes: 0
       },
       storage_bytes: 0,
       segment_count: 0,
       configured_retention: "Unknown",
       retention_hours: 24,
       storage_segments_open: false,
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

  def handle_event("toggle-storage-segments", _params, socket) do
    {:noreply, update(socket, :storage_segments_open, &(!&1))}
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
    if socket.assigns.compaction_running do
      {:noreply, socket}
    else
      owner = self()
      ref = make_ref()
      engine = socket.assigns.engine

      spawn(fn ->
        result =
          Tay.compact(
            name: engine,
            timeout: 900_000,
            terminal_retention: {:hours, retention_hours}
          )

        send(owner, {:dashboard_compaction_result, ref, retention_hours, result})
      end)

      {:noreply,
       assign(socket,
         confirm_compaction: false,
         compaction_running: true,
         compaction_ref: ref,
         compaction_result: nil,
         flash_error: nil
       )}
    end
  end

  @impl true
  def handle_info({:tay_dashboard_refresh, signal}, socket) do
    {:noreply, Live.schedule_refresh(socket, signal)}
  end

  def handle_info({:tay_dashboard_refresh_tick, signal}, socket) do
    {:noreply, socket |> Live.finish_refresh(signal) |> assign(refresh_timer: nil) |> refresh()}
  end

  def handle_info(:tay_dashboard_refresh, socket) do
    {:noreply, socket |> assign(refresh_timer: nil) |> refresh()}
  end

  def handle_info(
        {:dashboard_compaction_result, ref, retention_hours, {:ok, stats}},
        %{assigns: %{compaction_ref: ref}} = socket
      ) do
    {:noreply,
     socket
     |> refresh()
     |> assign(
       compaction_running: false,
       compaction_ref: nil,
       compaction_result: compacted(stats, retention_hours)
     )}
  end

  def handle_info(
        {:dashboard_compaction_result, ref, _retention_hours, {:error, error}},
        %{assigns: %{compaction_ref: ref}} = socket
      ) do
    {:noreply,
     assign(socket,
       compaction_running: false,
       compaction_ref: nil,
       flash_error: Live.error_message(error)
     )}
  end

  def handle_info({:dashboard_compaction_result, _, _, _}, socket), do: {:noreply, socket}

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
      <div :if={@compaction_running} id="compaction-running" class="notice">
        Compaction is running in the background. Jobs and this dashboard remain available.
      </div>
      <h3>Job status</h3>
      <p class="section-help">Current jobs grouped by where they are in their lifecycle.</p>
      <div class="cards">
        <div :for={{state, count} <- @stats} class={["card", "state-#{state}"]}>
          <div>{state |> Atom.to_string() |> String.capitalize()}</div>
          <div class="count">{count}</div>
          <div class="card-help">{state_description(state)}</div>
        </div>
      </div>
      <section style="margin-top:28px">
        <h3>Application memory</h3>
        <p class="section-help">
          Memory currently managed by the Erlang runtime that hosts Tay and this dashboard. The three detail cards are parts of the total, not extra memory to add to it.
        </p>
        <div class="cards">
          <div class="card">
            <div>Total runtime memory</div>
            <div class="count">{format_bytes(@beam_memory.total)}</div>
            <div class="card-help">Everything allocated by Tay's Erlang runtime (BEAM).</div>
          </div>
          <div class="card">
            <div>Process memory</div>
            <div class="count">{format_bytes(@beam_memory.processes)}</div>
            <div class="card-help">Lightweight tasks that run jobs and dashboard work.</div>
          </div>
          <div class="card">
            <div>In-memory indexes</div>
            <div class="count">{format_bytes(@beam_memory.ets)}</div>
            <div class="card-help">Fast lookup tables (ETS) used for live runtime state.</div>
          </div>
          <div class="card">
            <div>Shared data buffers</div>
            <div class="count">{format_bytes(@beam_memory.binary)}</div>
            <div class="card-help">Strings and encoded data shared by runtime processes.</div>
          </div>
        </div>
      </section>
      <section style="margin-top:28px">
        <h3>Job data safeguards</h3>
        <p class="section-help">
          Current workload and the two independent safety limits applied to jobs that have not finished yet.
        </p>
        <div class="cards">
          <div class="card">
            <div>Active jobs</div>
            <div class="count">
              {available(@engine_available, @capacity.active_jobs)}
            </div>
            <div class="card-help">Waiting, scheduled, running, or waiting to retry.</div>
          </div>
          <div class="card">
            <div>Finished job history</div>
            <div class="count">
              {available(@engine_available, @capacity.terminal_jobs)}
            </div>
            <div class="card-help">Completed, cancelled, and discarded jobs kept on disk.</div>
          </div>
          <div class="card">
            <div>Active job memory budget</div>
            <div class="count">
              {available(
                @engine_available,
                "#{format_bytes(@capacity.bytes)} / #{format_bytes(@capacity.max_bytes)}"
              )}
            </div>
            <div class="card-help">Conservative in-memory estimate / configured limit.</div>
          </div>
        </div>
        <p class="section-help">
          Job counts are informational and are not capped. Active job data is a conservative in-memory estimate: encoded data, nested structures, and per-job overhead are all converted into one byte budget.
        </p>
      </section>
      <section style="margin-top:28px">
        <h3>Storage maintenance</h3>
        <p class="section-help">
          Durable job history on disk and the retention setting used by compaction.
        </p>
        <div class="cards">
          <div class="card">
            <div>Stored job history</div>
            <div class="count">{available(@engine_available, format_bytes(@storage_bytes))}</div>
            <div class="card-help">Live segment data, excluding temporary maintenance files.</div>
          </div>
          <div class="card">
            <div>Storage files</div>
            <div class="count">{available(@engine_available, @segment_count)}</div>
            <div class="card-help">Append-only segment files currently in use.</div>
          </div>
          <div class="card">
            <div>Finished-job retention</div>
            <div class="count">{available(@engine_available, @configured_retention)}</div>
            <div class="card-help">How long finished jobs are kept during compaction.</div>
          </div>
        </div>
        <p class="section-help">
          Compaction rewrites the job store and permanently removes finished jobs older than the selected retention period. Retention is time-based, not a disk quota.
        </p>
        <details
          :if={@storage_segments != []}
          id="storage-segments"
          open={@storage_segments_open}
        >
          <summary phx-click="toggle-storage-segments">
            Storage files ({length(@storage_segments)} shown)
          </summary>
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
          :if={!@confirm_compaction && !@compaction_running && @engine_available}
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
          <label for="terminal-retention-hours">Configure terminal retention</label>
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
          <p>
            A successful compaction stores this setting. It takes priority over the startup environment on subsequent restarts.
          </p>
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
            active_jobs: Map.get(status, :active_jobs, 0),
            terminal_jobs: Map.get(status, :terminal_jobs, terminal_count(stats)),
            bytes: Map.get(status, :active_state_bytes_charged, 0),
            max_bytes: Map.get(status, :max_state_bytes, 0)
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

  @doc false
  def format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1_048_576, do: format_unit(bytes, 1_024, "KiB")
  def format_bytes(bytes) when bytes < 1_073_741_824, do: format_unit(bytes, 1_048_576, "MiB")

  def format_bytes(bytes) when bytes < 1_099_511_627_776,
    do: format_unit(bytes, 1_073_741_824, "GiB")

  def format_bytes(bytes), do: format_unit(bytes, 1_099_511_627_776, "TiB")

  defp format_unit(bytes, divisor, unit) do
    value = Float.round(bytes / divisor, 2)

    number =
      if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)

    "#{number} #{unit}"
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

  defp state_description(:available), do: "Ready and waiting for a worker."
  defp state_description(:scheduled), do: "Waiting for its scheduled time."
  defp state_description(:executing), do: "Currently running on a worker."
  defp state_description(:retryable), do: "Waiting for another attempt."
  defp state_description(:completed), do: "Finished successfully."
  defp state_description(:cancelled), do: "Stopped before completion."
  defp state_description(:discarded), do: "Failed with no attempts left."

  defp segment_filename(id),
    do: id |> Integer.to_string() |> String.pad_leading(20, "0") |> Kernel.<>(".tay")

  defp sequence_range(%{count: 0}), do: "—"

  defp sequence_range(segment),
    do: "#{segment.first_sequence}–#{segment.last_sequence}"
end
