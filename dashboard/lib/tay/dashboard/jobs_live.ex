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
        Page {@page} · showing {length(@jobs)} job{if length(@jobs) == 1, do: "", else: "s"}
      </p>
      <p :if={@next_cursor}>
        <a
          id="next-page"
          href={
            jobs_path(
              @dashboard_path,
              drop_empty(@filters)
              |> Map.put("cursor", @next_cursor)
              |> Map.put("page", @page + 1)
            )
          }
        >Next page →</a>
      </p>
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
        assign(socket,
          jobs: result_page.jobs,
          next_cursor: result_page.next_cursor,
          page: page_number,
          filters: filters,
          flash_error: nil
        )

      {:error, error} ->
        assign(socket,
          jobs: [],
          next_cursor: nil,
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
  defp short(id), do: String.slice(id, 0, 12) <> "…"
  defp time(nil), do: "—"
  defp time(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp time(value), do: to_string(value)
end
