defmodule Tay.Dashboard.OverviewLive do
  @moduledoc false
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @resource_refresh_ms 1_000

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
       beam_cpu: %{usage: nil, schedulers: :erlang.system_info(:schedulers_online), run_queue: 0},
       scheduler_sample: nil,
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
       storage_segments_truncated: false,
       expanded_segment: nil,
       expanded_record: nil,
       expanded_record_details: nil,
       segment_records: [],
       segment_records_total: 0,
       segment_records_page: 1,
       segment_record_cursor: nil,
       segment_record_next_cursor: nil,
       segment_record_cursor_history: []
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

  def handle_event("toggle-segment-records", %{"id" => value}, socket) do
    with {id, ""} <- Integer.parse(value),
         false <- socket.assigns.expanded_segment == id,
         {:ok, page} <- Tay.storage_records(id, limit: 50, name: socket.assigns.engine) do
      {:noreply,
       assign(socket,
         expanded_segment: id,
         expanded_record: nil,
         expanded_record_details: nil,
         segment_records: page.records,
         segment_records_total: page.total_count,
         segment_records_page: 1,
         segment_record_cursor: page.cursor,
         segment_record_next_cursor: page.next_cursor,
         segment_record_cursor_history: [],
         flash_error: nil
       )}
    else
      true ->
        {:noreply,
         assign(socket,
           expanded_segment: nil,
           expanded_record: nil,
           expanded_record_details: nil,
           segment_records: [],
           segment_records_total: 0,
           segment_records_page: 1,
           segment_record_cursor: nil,
           segment_record_next_cursor: nil,
           segment_record_cursor_history: []
         )}

      {:error, error} ->
        {:noreply, assign(socket, flash_error: Live.error_message(error))}

      _ ->
        {:noreply, assign(socket, flash_error: "Invalid storage segment.")}
    end
  end

  def handle_event("toggle-record-details", %{"sequence" => value}, socket) do
    case Integer.parse(value) do
      {sequence, ""} when socket.assigns.expanded_record == sequence ->
        {:noreply, assign(socket, expanded_record: nil, expanded_record_details: nil)}

      {sequence, ""} ->
        with %{offset: offset} <-
               Enum.find(socket.assigns.segment_records, &(&1.sequence == sequence)),
             segment_id when is_integer(segment_id) <- socket.assigns.expanded_segment,
             {:ok, details} <-
               Tay.storage_record(segment_id, offset, sequence, name: socket.assigns.engine) do
          {:noreply,
           assign(socket,
             expanded_record: sequence,
             expanded_record_details: details,
             flash_error: nil
           )}
        else
          {:error, error} ->
            {:noreply, assign(socket, flash_error: Live.error_message(error))}

          _ ->
            {:noreply, assign(socket, flash_error: "Storage record is no longer available.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("next-segment-records", _params, socket) do
    case socket.assigns.segment_record_next_cursor do
      cursor when is_integer(cursor) ->
        history = [
          socket.assigns.segment_record_cursor | socket.assigns.segment_record_cursor_history
        ]

        load_segment_page(socket, cursor, socket.assigns.segment_records_page + 1, history)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("previous-segment-records", _params, socket) do
    case socket.assigns.segment_record_cursor_history do
      [cursor | history] ->
        load_segment_page(
          socket,
          cursor,
          max(socket.assigns.segment_records_page - 1, 1),
          history
        )

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("compact", %{"terminal_retention_hours" => value}, socket) do
    case Integer.parse(value) do
      {hours, ""} when hours >= 0 ->
        compact(socket, hours)

      _ ->
        {:noreply,
         assign(socket, flash_error: "Retention must be a non-negative number of hours.")}
    end
  end

  def handle_event("compact", _params, socket) do
    compact(socket, socket.assigns.retention_hours)
  end

  defp load_segment_page(socket, cursor, page_number, history) do
    case Tay.storage_records(socket.assigns.expanded_segment,
           cursor: cursor,
           limit: 50,
           name: socket.assigns.engine
         ) do
      {:ok, page} ->
        {:noreply,
         assign(socket,
           expanded_record: nil,
           expanded_record_details: nil,
           segment_records: page.records,
           segment_records_total: page.total_count,
           segment_records_page: page_number,
           segment_record_cursor: page.cursor,
           segment_record_next_cursor: page.next_cursor,
           segment_record_cursor_history: history,
           flash_error: nil
         )}

      {:error, error} ->
        {:noreply, assign(socket, flash_error: Live.error_message(error))}
    end
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
    {:noreply, socket |> Live.finish_refresh(signal) |> refresh()}
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
        <.link
          :for={{state, count} <- @stats}
          id={"job-state-#{state}"}
          class={["card", "job-state-card", "state-#{state}"]}
          navigate={@dashboard_path <> "/jobs?state=" <> Atom.to_string(state)}
          aria-label={"View #{state} jobs"}
        >
          <div>{state |> Atom.to_string() |> String.capitalize()}</div>
          <div class="count">{count}</div>
          <div class="card-help">{state_description(state)}</div>
        </.link>
      </div>
      <section style="margin-top:28px">
        <h3>Processor use</h3>
        <p class="section-help">
          CPU activity inside the Erlang runtime that hosts Tay. Utilization is sampled between dashboard refreshes and normalized to the available BEAM scheduler capacity.
        </p>
        <div class="cards">
          <div class="card" id="beam-cpu-utilization">
            <div>BEAM CPU utilization</div>
            <div class="count">{format_cpu(@beam_cpu.usage)}</div>
            <div class="card-help">
              Scheduler time used by Tay, its workers, and this dashboard during the latest sample.
            </div>
          </div>
          <div class="card" id="beam-scheduler-capacity">
            <div>Scheduler capacity</div>
            <div class="count">{@beam_cpu.schedulers}</div>
            <div class="card-help">Normal BEAM schedulers currently online.</div>
          </div>
          <div class="card" id="beam-run-queue">
            <div>Run queue</div>
            <div class="count">{@beam_cpu.run_queue}</div>
            <div class="card-help">Runnable work waiting for scheduler time at this instant.</div>
          </div>
        </div>
        <p class="section-note">
          BEAM does not attribute CPU time to a single library. If other applications share this runtime, their work is included in the utilization value.
        </p>
      </section>
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
        <p class="section-note">
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
        <p class="section-note">
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
              <%= for segment <- @storage_segments do %>
                <tr>
                  <td>
                    <button
                      class="secondary"
                      phx-click="toggle-segment-records"
                      phx-value-id={segment.id}
                      aria-expanded={@expanded_segment == segment.id}
                    >
                      <code>{segment_filename(segment.id)}</code>
                    </button>
                  </td>
                  <td><span class={["state", "state-#{segment.state}"]}>{segment.state}</span></td>
                  <td>{format_bytes(segment.bytes)}</td>
                  <td>{segment.count}</td>
                  <td>{sequence_range(segment)}</td>
                </tr>
                <tr :if={@expanded_segment == segment.id} id={"segment-records-#{segment.id}"}>
                  <td colspan="5">
                    <p class="section-help">
                      Page {@segment_records_page} · {length(@segment_records)} records shown · {@segment_records_total} total
                    </p>
                    <div class="record-table-scroll">
                      <table>
                        <thead>
                          <tr>
                            <th>SEQUENCE</th>
                            <th>OFFSET</th>
                            <th>EVENT</th>
                            <th>ENTITY</th>
                            <th>REVISION</th>
                            <th>RECORDED AT</th>
                            <th>PAYLOAD</th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for record <- @segment_records do %>
                            <tr id={"segment-record-#{record.sequence}"}>
                              <td>{record.sequence}</td>
                              <td>{record.offset}</td>
                              <td>
                                <button
                                  class="record-toggle"
                                  phx-click="toggle-record-details"
                                  phx-value-sequence={record.sequence}
                                  aria-expanded={@expanded_record == record.sequence}
                                  aria-controls={"record-details-#{record.sequence}"}
                                >
                                  <span aria-hidden="true">
                                    {if @expanded_record == record.sequence, do: "▾", else: "▸"}
                                  </span>
                                  {record_label(record)}
                                </button>
                                <div class="record-summary">{record.inspection.summary}</div>
                              </td>
                              <td>
                                <div>{record.inspection.entity || "—"}</div>
                                <.link
                                  :if={record.inspection.entity == "job"}
                                  navigate={@dashboard_path <> "/jobs/" <> record.inspection.identity}
                                  title="Open job details"
                                >
                                  <code class="record-identity">{record.inspection.identity}</code>
                                </.link>
                                <code
                                  :if={record.inspection.entity != "job"}
                                  class="record-identity"
                                >{record.inspection.identity}</code>
                              </td>
                              <td>{record_revision(record.inspection.revision)}</td>
                              <td>{record_time(record.inspection.at)}</td>
                              <td>
                                {format_bytes(record.payload_bytes)}
                                <div class="record-schema">
                                  schema {record.payload_schema_version}
                                </div>
                              </td>
                            </tr>
                            <tr
                              :if={@expanded_record == record.sequence}
                              id={"record-details-#{record.sequence}"}
                              class="record-detail-row"
                            >
                              <td colspan="7">
                                <div class="record-detail-heading">
                                  Record details · sequence {record.sequence} · offset {record.offset}
                                </div>
                                <dl class="record-detail-list">
                                  <div
                                    :for={field <- @expanded_record_details.fields}
                                    class="record-detail-field"
                                  >
                                    <dt>{field.label}</dt>
                                    <dd>
                                      <div class="record-detail-value">{field.value}</div>
                                      <div :if={field.help} class="record-detail-help">
                                        {field.help}
                                      </div>
                                    </dd>
                                  </div>
                                </dl>
                                <details class="technical-details record-raw-payload">
                                  <summary>Raw decoded payload</summary>
                                  <pre>{@expanded_record_details.details}</pre>
                                </details>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                    <div class="actions pagination">
                      <button
                        :if={@segment_record_cursor_history != []}
                        class="secondary"
                        phx-click="previous-segment-records"
                      >
                        Previous
                      </button>
                      <span>Page {@segment_records_page}</span>
                      <button
                        :if={@segment_record_next_cursor}
                        class="secondary"
                        phx-click="next-segment-records"
                      >
                        Next
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
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
            Set it to 0 to remove all completed, cancelled, and discarded jobs.
          </p>
          <label for="terminal-retention-hours">Configure terminal retention</label>
          <div class="actions">
            <input
              id="terminal-retention-hours"
              name="terminal_retention_hours"
              type="number"
              min="0"
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

    {beam_cpu, scheduler_sample} =
      sample_cpu(socket.assigns.scheduler_sample, Phoenix.LiveView.connected?(socket))

    timer = resource_refresh_timer(socket)

    case Tay.stats(name: socket.assigns.engine) do
      {:ok, stats} ->
        retention = Map.get(status, :compaction_terminal_retention, {:hours, 24})
        retention_hours = retention_hours(retention)

        assign(socket,
          stats: stats,
          engine_available: true,
          engine_state: Map.get(status, :state, :ready),
          engine_phase: Map.get(status, :phase),
          refresh_timer: timer,
          beam_cpu: beam_cpu,
          scheduler_sample: scheduler_sample,
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
        assign(socket,
          stats: %{},
          engine_available: false,
          engine_state: Map.get(status, :state, :unavailable),
          engine_phase: Map.get(status, :phase),
          refresh_timer: timer,
          beam_cpu: beam_cpu,
          scheduler_sample: scheduler_sample,
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

  defp resource_refresh_timer(socket) do
    if socket.assigns.refresh_timer, do: Process.cancel_timer(socket.assigns.refresh_timer)

    if Phoenix.LiveView.connected?(socket),
      do: Process.send_after(self(), :tay_dashboard_refresh, @resource_refresh_ms),
      else: nil
  end

  defp sample_cpu(previous, connected?) do
    schedulers = :erlang.system_info(:schedulers_online)

    if connected? do
      sample_connected_cpu(previous, schedulers)
    else
      {%{usage: nil, schedulers: schedulers, run_queue: :erlang.statistics(:run_queue)}, previous}
    end
  end

  defp sample_connected_cpu(previous, schedulers) do
    current = scheduler_wall_time()

    {%{
       usage: scheduler_utilization(previous, current, schedulers),
       schedulers: schedulers,
       run_queue: :erlang.statistics(:run_queue)
     }, current}
  end

  defp scheduler_wall_time do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined ->
        _previous = :erlang.system_flag(:scheduler_wall_time, true)
        :erlang.statistics(:scheduler_wall_time)

      sample ->
        sample
    end
  end

  @doc false
  def scheduler_utilization(nil, _current, _schedulers), do: nil

  def scheduler_utilization(previous, current, schedulers)
      when is_list(previous) and is_list(current) and is_integer(schedulers) and schedulers > 0 do
    previous = Map.new(previous, fn {id, active, total} -> {id, {active, total}} end)

    {active_delta, total_delta} =
      Enum.reduce(current, {0, 0}, fn
        {id, active, total}, {active_acc, total_acc} when id <= schedulers ->
          case Map.get(previous, id) do
            {old_active, old_total} when active >= old_active and total >= old_total ->
              {active_acc + active - old_active, total_acc + total - old_total}

            _ ->
              {active_acc, total_acc}
          end

        _, acc ->
          acc
      end)

    if total_delta > 0,
      do: (active_delta / total_delta * 100) |> max(0.0) |> min(100.0),
      else: nil
  end

  def scheduler_utilization(_, _, _), do: nil

  defp available(true, value), do: value
  defp available(false, _value), do: "—"

  defp compacted(stats, retention_hours) do
    expired = Map.get(stats, :expired_jobs, 0)
    retained = Map.get(stats, :retained_terminal_jobs, 0)
    reclaimed = Map.get(stats, :net_reclaimed_bytes, Map.get(stats, :reclaimed_bytes, 0))

    if retention_hours == 0 do
      "Compaction completed: full terminal-history purge removed #{expired} terminal jobs, reclaimed #{format_bytes(reclaimed)}, and retained #{retained}. Future finished-job retention is 1 h."
    else
      "Compaction completed with #{retention_hours} h retention: removed #{expired} expired jobs, reclaimed #{format_bytes(reclaimed)}, and retained #{retained} terminal jobs."
    end
  end

  @doc false
  def format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1_048_576, do: format_unit(bytes, 1_024, "KB")
  def format_bytes(bytes) when bytes < 1_073_741_824, do: format_unit(bytes, 1_048_576, "MB")

  def format_bytes(bytes) when bytes < 1_099_511_627_776,
    do: format_unit(bytes, 1_073_741_824, "GB")

  def format_bytes(bytes), do: format_unit(bytes, 1_099_511_627_776, "TB")

  @doc false
  def format_cpu(nil), do: "Collecting…"
  def format_cpu(value), do: "#{Float.round(value, 1)}%"

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

  defp lifecycle_message(state, phase) do
    suffix = if phase, do: " (#{phase})", else: ""

    "Engine state: #{state}#{suffix}. Capacity and storage values are unavailable until recovery completes."
  end

  defp lifecycle_error(%{state: :compacting}, _error), do: nil
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

  defp record_revision(nil), do: "—"
  defp record_revision(revision), do: revision

  defp record_time(nil), do: "—"

  defp record_time(milliseconds) when is_integer(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S.%3f UTC")
      {:error, _} -> to_string(milliseconds)
    end
  end

  defp record_time(value), do: to_string(value)

  defp record_label(%{payload_schema_version: 2, record_type: type}) do
    case Tay.Event.V2.type_name(type) do
      nil -> "event #{type}"
      name -> name |> Atom.to_string() |> String.replace("_", " ")
    end
  end

  defp record_label(%{payload_schema_version: 1, record_type: 7}), do: "job snapshot"
  defp record_label(%{payload_schema_version: 1, record_type: 8}), do: "job mutation"

  defp record_label(%{payload_schema_version: 1, record_type: type}) when type in 1..6 do
    type |> Tay.Event.V2.type_name() |> Atom.to_string() |> String.replace("_", " ")
  end

  defp record_label(%{record_type: type}), do: "record #{type}"
end
