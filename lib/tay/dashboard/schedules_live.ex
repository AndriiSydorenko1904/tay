defmodule Tay.Dashboard.SchedulesLive do
  @moduledoc false
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> Live.initialize(session)
     |> assign(
       schedules: [],
       cursor: nil,
       next_cursor: nil,
       engine_available: false,
       refresh_timer: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_event("cancel", %{"id" => id}, socket) do
    case Tay.cancel_schedule(id, name: socket.assigns.engine) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, error} -> {:noreply, assign(socket, flash_error: Live.error_message(error))}
    end
  end

  def handle_event("next", _, socket),
    do: {:noreply, socket |> assign(cursor: socket.assigns.next_cursor) |> refresh()}

  def handle_event("first", _, socket), do: {:noreply, socket |> assign(cursor: nil) |> refresh()}

  @impl true
  def handle_info({:tay_dashboard_refresh, signal}, socket),
    do: {:noreply, Live.schedule_refresh(socket, signal)}

  def handle_info({:tay_dashboard_refresh_tick, signal}, socket),
    do: {:noreply, socket |> Live.finish_refresh(signal) |> refresh()}

  @impl true
  def terminate(_reason, socket), do: Live.terminate(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Live.shell current={:schedules} path={@dashboard_path}>
      <h2>Schedules</h2>
      <p class="section-help">Durable recurring task declarations and their next run.</p>
      <div :if={@flash_error} class="error">{@flash_error}</div>
      <div :if={!@engine_available} class="notice">Tay is currently unavailable.</div>
      <p :if={@engine_available && @schedules == []} class="notice">No schedules registered.</p>
      <table :if={@schedules != []} id="schedules">
        <thead>
          <tr>
            <th>ID</th>
            <th>TASK</th>
            <th>EXPRESSION</th>
            <th>NEXT RUN</th>
            <th>LAST RUN</th>
            <th>STATE</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={schedule <- @schedules} id={"schedule-#{schedule.id}"}>
            <td><code>{schedule.id}</code></td>
            <td><code>{schedule.task}</code></td>
            <td>{expression(schedule)}</td>
            <td>{time(schedule.next_at)}</td>
            <td>{time(schedule.last_at)}</td>
            <td>
              <span class={[
                "badge",
                if(schedule.cancelled_at, do: "state-cancelled", else: "state-scheduled")
              ]}>
                {if(schedule.cancelled_at, do: "cancelled", else: "active")}
              </span>
            </td>
            <td>
              <button
                :if={!schedule.cancelled_at}
                class="secondary"
                phx-click="cancel"
                phx-value-id={schedule.id}
                data-confirm="Cancel this recurring schedule?"
              >Cancel</button>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@cursor || @next_cursor}>
        <button :if={@cursor} class="secondary" phx-click="first">First page</button>
        <button :if={@next_cursor} class="secondary" phx-click="next">Next page</button>
      </div>
    </Live.shell>
    """
  end

  defp refresh(socket) do
    case Tay.schedule_page(name: socket.assigns.engine, cursor: socket.assigns.cursor) do
      {:ok, page} ->
        assign(socket,
          schedules: page.schedules,
          next_cursor: page.next_cursor,
          engine_available: true,
          flash_error: nil
        )

      {:error, error} ->
        assign(socket,
          schedules: [],
          engine_available: false,
          flash_error: Live.error_message(error)
        )
    end
  end

  defp expression(%{kind: "cron"} = schedule),
    do: "#{schedule.expression} (#{schedule.timezone || "UTC"})"

  defp expression(%{kind: "every", expression: milliseconds}),
    do: "every #{duration(milliseconds)}"

  defp expression(_), do: "—"

  defp duration(ms) when rem(ms, 86_400_000) == 0, do: "#{div(ms, 86_400_000)} d"
  defp duration(ms) when rem(ms, 3_600_000) == 0, do: "#{div(ms, 3_600_000)} h"
  defp duration(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)} min"
  defp duration(ms) when rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)} s"
  defp duration(ms), do: "#{ms} ms"

  defp time(nil), do: "—"

  defp time(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "—"
    end
  end
end
