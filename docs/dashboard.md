# Tay Dashboard

Tay Dashboard is the Phoenix LiveView dashboard published as the independent
[`tay_dashboard`](https://hex.pm/packages/tay_dashboard) package. It mounts inside an existing
Phoenix application and communicates with Tay only through its public
inspection and administration APIs. It does not start a separate server;
the standalone release can serve it when explicitly enabled.

There are two supported deployment shapes:

1. Mount `tay_dashboard` in an existing Phoenix application.
2. Run the `tay` OCI image with `TAY_ENABLE_DASHBOARD=true`; it contains one Tay
   Engine, its Unix executor socket, and a small Phoenix host.

Dashboard source lives in `apps/tay_dashboard/lib/tay/dashboard/`. Phoenix and
LiveView are dependencies of `tay_dashboard`. The package pulls in `tay_http`
and core `tay` transitively, while core stays framework-free.

## Installation

Add the complete dashboard bundle to the host Phoenix application's
dependencies:

```elixir
def deps do
  [
    {:tay_dashboard, "~> 1.6"}
  ]
end
```

This installs `tay_http` and `tay` transitively, so the same dependency also
provides HTTP(S) and Unix-socket transports.

Installing the package makes these capabilities available but does not start or
expose a dashboard endpoint automatically. In an existing Phoenix application,
the dashboard is enabled by mounting `tay_dashboard/2` in the host router. The
`TAY_ENABLE_DASHBOARD` and `TAY_DASHBOARD_SECRET_KEY_BASE` environment variables
are not used in this deployment shape: browser sessions, CSRF protection, and
LiveView use the host endpoint's existing `secret_key_base`.

Tay 1.x requires Elixir 1.20, Phoenix 1.8, and Phoenix LiveView 1.2.
The host endpoint must have a working LiveView socket and PubSub,
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

## Dashboard-enabled container

The `ghcr.io/andriisydorenko1904/tay:<version>` image enables its bundled UI
with `TAY_ENABLE_DASHBOARD=true`. From the repository root, start the complete
example with:

```sh
TAY_IMAGE=tay:local TAY_ENABLE_DASHBOARD=true docker compose up --build
```

Then open <http://localhost:4000/tay>. The example publishes the port only on
host loopback and does not enable application-level authentication. Optional
HTTP Basic authentication is enabled by setting both `TAY_DASHBOARD_USERNAME`
and `TAY_DASHBOARD_PASSWORD`. For a real deployment, keep the UI on a trusted
network or behind a trusted ingress and set a random
`TAY_DASHBOARD_SECRET_KEY_BASE`.

Unlike package installation in a host Phoenix application, the standalone
release owns its Phoenix endpoint. It therefore requires both explicit runtime
activation and a stable signing secret:

| Deployment | Dashboard activation | Phoenix signing secret |
| --- | --- | --- |
| `tay_dashboard` in a host Phoenix application | Mount `tay_dashboard/2` in the host router | Host endpoint's existing `secret_key_base` |
| Standalone/container without UI | Disabled by default | Not required |
| Standalone/container with UI | `TAY_ENABLE_DASHBOARD=true` | `TAY_DASHBOARD_SECRET_KEY_BASE`, at least 64 random bytes |

Package presence deliberately does not imply network activation. The official
image contains the complete bundle even in headless deployments, so enabling
the endpoint merely because `tay_dashboard` is installed would expose an
administrative UI unexpectedly.

See the [container deployment guide](dashboard-container.md) for `docker run`, Compose,
configuration, persistence, worker connectivity, upgrades, and the security
model.

## Pages

- **Overview** shows incrementally maintained counts for available, scheduled,
  executing, retryable, completed, cancelled, and discarded jobs. It samples
  BEAM CPU utilization, online scheduler capacity, run-queue pressure, and
  runtime memory, and exposes a confirmation-protected manual compaction action
  with a result summary.
- **Jobs** provides first, previous, next, and last cursor navigation with exact
  result/page totals, plus state, queue, and partial worker-key filters. Details
  show safe public job fields, bounded argument rendering, readable failure
  explanations with optional technical codes, and revision-checked Retry/Cancel
  actions when valid.
- **Queues** shows configured concurrency, current execution use, retained job
  counts, and volatile Pause/Resume controls.
- **Schedules** shows durable cron/interval declarations, their next and last
  run, active/cancelled state, and a revision-safe cancellation control.
- **Overview → Storage files** can expand a segment into a bounded physical
  record table with sequence, byte offset, semantic type, schema, and payload
  size. Records use 50-item offset-cursor pages. Expanding one record loads its
  decoded details on demand, explains wire codes and tracking tokens, and keeps
  the bounded raw representation under a separate disclosure control.

The dashboard follows the operating-system light/dark preference by default.
The Theme control stores an explicit override in the browser's local storage.

Successful Tay transitions emit bounded telemetry. Connected dashboard
LiveViews receive refresh hints and re-run only bounded public queries. Overview
also samples bounded runtime summaries once per second so CPU utilization remains
meaningful while the engine is idle; it does not scan job history. CPU is the
share of normal BEAM scheduler capacity used between samples and therefore
includes other applications if they share Tay's VM. Opening a connected Overview
enables Erlang scheduler wall-time accounting for the runtime. Live pages handle
stale revisions, missing jobs, invalid URLs, and unavailable engines as ordinary
visible errors. Storage inspection decoding runs outside the Engine command loop,
uses bounded display values and a bounded preview cache, and does not cache
complete payloads.

## Operational boundary

The dashboard never reads Tay ETS tables, storage files, internal GenServers,
or private engine modules. All mutations go through `Tay.cancel/2`,
`Tay.retry/2`, `Tay.pause_queue/2`, `Tay.resume_queue/2`, and `Tay.compact/1`.
It adds no dashboard storage. Manual compaction rewrites the durable store and
permanently removes terminal jobs that have expired under the configured
retention policy, so the UI requires an explicit confirmation. Store-v2
candidate preparation keeps admission and execution live and is shown as
storage maintenance; only the short fenced epoch switch is unavailable. The
the short publication fence is shown as `compacting / switching`. Cursor pages are
weakly consistent under concurrent job changes; refresh to reconcile a changing
result set.

## Documentation

The maintained documentation sources are this guide and module documentation
under `apps/tay_dashboard/lib/tay/dashboard/`. Generated `doc/` output is
ignored. Build it from the dashboard application with:

```sh
cd apps/tay_dashboard
mix docs
```

The dashboard and core packages publish their own focused ExDoc output.
