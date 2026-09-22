# Tay Dashboard

Tay Dashboard is the official optional Phoenix LiveView dashboard for
[Tay](https://hex.pm/packages/tay). It mounts inside an existing Phoenix
application and communicates with Tay only through its public inspection and
administration APIs. It does not start a separate server and Tay itself remains
usable without Phoenix, LiveView, or Plug.

## Installation

Add both packages to the host Phoenix application's dependencies:

```elixir
def deps do
  [
    {:tay, "~> 0.8.0"},
    {:tay_dashboard, "~> 0.8.0"}
  ]
end
```

Tay Dashboard 0.8.x requires Elixir 1.20, Tay 0.8.x, Phoenix 1.8, and Phoenix
LiveView 1.2. The host endpoint must have a working LiveView socket and PubSub,
as a normal Phoenix LiveView application does.

## Router integration

Import the router helper and mount it in a browser pipeline:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import Tay.Dashboard.Router

  scope "/admin" do
    pipe_through [:browser, :require_admin]

    tay_dashboard "/tay"
  end
end
```

For a nondefault named engine:

```elixir
tay_dashboard "/tay", engine: MyApp.TayEngine
```

The macro does not add a pipeline. In particular, Tay Dashboard does **not**
provide or imply authentication. Place it behind the host application's own
administrator authentication and authorization plugs. Anyone who can access
the routes can view job arguments and invoke the available administrative
controls.

## Pages

- **Overview** shows incrementally maintained counts for available, scheduled,
  executing, retryable, completed, cancelled, and discarded jobs.
- **Jobs** provides bounded cursor pagination and state, queue, and worker-key
  filters. Details show safe public job fields, bounded argument rendering, the
  last diagnostic, and revision-checked Retry/Cancel actions when valid.
- **Queues** shows configured concurrency, current execution use, retained job
  counts, and volatile Pause/Resume controls.

Successful Tay transitions emit bounded telemetry. Connected dashboard
LiveViews receive refresh hints and re-run only bounded public queries; the
dashboard does not poll or scan all history. Live pages handle stale revisions,
missing jobs, invalid URLs, and unavailable engines as ordinary visible errors.

## Operational boundary

The dashboard never reads Tay ETS tables, storage files, internal GenServers,
or private engine modules. All mutations go through `Tay.cancel/2`,
`Tay.retry/2`, `Tay.pause_queue/2`, and `Tay.resume_queue/2`. It adds no durable
events or dashboard storage. Cursor pages are weakly consistent under concurrent
job changes; refresh to reconcile a changing result set.
