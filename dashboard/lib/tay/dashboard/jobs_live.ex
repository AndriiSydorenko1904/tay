defmodule Tay.Dashboard.JobsLive do
  @moduledoc false
  use Phoenix.LiveView
  alias Tay.Dashboard.Live

  @impl true
  def mount(_params, session, socket), do: {:ok, Live.initialize(socket, session)}

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "state" => Map.get(params, "state", ""),
      "queue" => Map.get(params, "queue", ""),
      "worker" => Map.get(params, "worker", "")
    }

    page = page_number(Map.get(params, "page"))
    {:noreply, load(socket, filters, Map.get(params, "cursor"), page)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query = params |> Map.take(["state", "queue", "worker"]) |> drop_empty()
    {:noreply, push_patch(socket, to: jobs_path(socket, query))}
  end

  @impl true
  def handle_info(:tay_dashboard_refresh, socket) do
    {:noreply, load(socket, socket.assigns.filters, nil, 1)}
  end

  @impl true
  def terminate(_reason, socket), do: Live.terminate(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Live.shell current={:jobs} path={@dashboard_path}>
      <h2>Jobs</h2>
      <form
        id="job-filters"
        action={@dashboard_path <> "/jobs"}
        method="get"
        phx-change="filter"
        phx-submit="filter"
        class="actions"
      >
        <label>
          State<br />
          <select name="state">
            <option value="">All states</option>
            <option
              :for={state <- Live.states()}
              value={state}
              selected={@filters["state"] == Atom.to_string(state)}
            >
              {state}
            </option>
          </select>
        </label>
        <label>Queue<br /><input name="queue" value={@filters["queue"]} placeholder="default" /></label>
        <label>Worker key contains<br /><input
          name="worker"
          value={@filters["worker"]}
          placeholder="worker.v1"
        /></label>
        <button type="submit">Apply filters</button>
      </form>
      <div :if={@flash_error} class="error">{@flash_error}</div>
      <table>
        <thead>
          <tr>
            <th>ID</th><th>Worker</th><th>Queue</th><th>State</th><th>Attempt</th><th>Inserted</th><th>
              Scheduled
            </th>
          </tr>
        </thead>
        <tbody id="jobs">
          <tr :for={job <- @jobs} id={"job-#{job.id}"}>
            <td><a href={@dashboard_path <> "/jobs/" <> job.id}>{short(job.id)}</a></td>
            <td>{job.worker_key}</td><td>{job.queue}</td><td>
              <span class="badge">{job.state}</span>
            </td>
            <td>{job.attempt}/{job.max_attempts}</td><td>{time(job.inserted_at)}</td><td>
              {time(job.scheduled_at)}
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@jobs == [] && !@flash_error}>No jobs match this page.</p>
      <p :if={!@flash_error} id="page-summary">
        Page {@page} of {@total_pages} · showing {length(@jobs)} of {@total_count} {job_word(
          @total_count
        )}
      </p>
      <nav :if={!@flash_error && @total_pages > 1} aria-label="Job pages" class="actions">
        <a :if={@page > 1} id="first-page" href={page_path(@dashboard_path, @filters, nil, 1)}>
          ⇤ First page
        </a>
        <a
          :if={@previous_cursor && @page > 1}
          id="previous-page"
          href={page_path(@dashboard_path, @filters, @previous_cursor, @page - 1)}
        >← Previous page</a>
        <span aria-current="page">{@page} / {@total_pages}</span>
        <a
          :if={@next_cursor}
          id="next-page"
          href={page_path(@dashboard_path, @filters, @next_cursor, @page + 1)}
        >Next page →</a>
        <a
          :if={@last_cursor && @page < @total_pages}
          id="last-page"
          href={page_path(@dashboard_path, @filters, @last_cursor, @total_pages)}
        >Last page ⇥</a>
      </nav>
    </Live.shell>
    """
  end

  defp load(socket, filters, cursor, page_number) do
    options = [name: socket.assigns.engine, limit: 50]

    state =
      case present(filters["state"]) do
        nil -> nil
        value -> Live.state_param(value) || value
      end

    options = add(options, :state, state)
    options = add(options, :queue, present(filters["queue"]))
    options = add(options, :worker_contains, present(filters["worker"]))
    options = add(options, :cursor, cursor)

    case Tay.jobs(options) do
      {:ok, result_page} ->
        # Tay 0.9.7 adds exact totals and bidirectional cursors. Keep the
        # dashboard usable with the declared 0.9.6 floor while applications
        # roll core and dashboard upgrades independently.
        total_count =
          Map.get_lazy(result_page, :total_count, fn ->
            (page_number - 1) * 50 + length(result_page.jobs) +
              if(result_page.next_cursor, do: 1, else: 0)
          end)

        total_pages = max(ceil_div(total_count, 50), 1)

        assign(socket,
          jobs: result_page.jobs,
          next_cursor: result_page.next_cursor,
          previous_cursor: Map.get(result_page, :previous_cursor),
          last_cursor: Map.get(result_page, :last_cursor),
          total_count: total_count,
          total_pages: total_pages,
          page: min(page_number, total_pages),
          filters: filters,
          flash_error: nil
        )

      {:error, error} ->
        assign(socket,
          jobs: [],
          next_cursor: nil,
          previous_cursor: nil,
          last_cursor: nil,
          total_count: 0,
          total_pages: 1,
          page: page_number,
          filters: filters,
          flash_error: Live.error_message(error)
        )
    end
  end

  defp jobs_path(socket, query) when is_struct(socket),
    do: jobs_path(socket.assigns.dashboard_path, query)

  defp jobs_path(path, query) do
    case URI.encode_query(query) do
      "" -> path <> "/jobs"
      encoded -> path <> "/jobs?" <> encoded
    end
  end

  defp page_path(path, filters, cursor, page) do
    filters
    |> drop_empty()
    |> maybe_put("cursor", cursor)
    |> maybe_put("page", if(page == 1, do: nil, else: page))
    |> then(&jobs_path(path, &1))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp add(options, _key, nil), do: options
  defp add(options, key, value), do: Keyword.put(options, key, value)
  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp page_number(_), do: 1
  defp drop_empty(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  defp job_word(1), do: "job"
  defp job_word(_), do: "jobs"
  defp short(id), do: String.slice(id, 0, 12) <> "…"
  defp time(nil), do: "—"
  defp time(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp time(value), do: to_string(value)
end
