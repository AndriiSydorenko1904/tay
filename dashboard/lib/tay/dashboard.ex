defmodule Tay.Dashboard do
  @moduledoc """
  The optional Phoenix LiveView dashboard for Tay.

  Tay Dashboard renders bounded job, queue, and state inspection through Tay's
  public API. It can retry or cancel eligible jobs and pause or resume queues.
  It does not read Store files or private Engine state.

  Mount the dashboard with `Tay.Dashboard.Router.tay_dashboard/2` inside a
  browser pipeline that enforces administrator authentication:

      import Tay.Dashboard.Router

      scope "/admin" do
        pipe_through [:browser, :require_admin]
        tay_dashboard "/tay"
      end

  The package does not start an HTTP server. Applications that do not already
  have Phoenix can instead use the dashboard-enabled OCI image described in
  the container deployment guide.

  ## Security

  Anyone who can reach the mounted routes can see job arguments and use the
  available administrative actions. Authentication and authorization belong to
  the embedding application; the router macro deliberately adds neither.

  ## Consistency

  LiveViews receive bounded telemetry refresh hints and repeat bounded public
  queries. Cursor pages are weakly consistent while jobs change. The UI treats
  stale revisions and unavailable Engines as visible operational errors.
  """
end
