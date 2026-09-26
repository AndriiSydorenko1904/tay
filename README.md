# Tay

**Durable background jobs without a database or message broker.**

Tay is a durable, single-node background-job engine with its own append-only
storage. It can run embedded inside an Elixir application or as standalone
infrastructure in a production OCI container.

No DataBase. No Redis. No RabbitMQ. Tay owns its durable job state itself.

```text
Application / Worker
        │
        │ local Unix socket
        ▼
┌─────────────────────┐
│         Tay         │
│                     │
│ queues · retries    │
│ schedules · cron    │
│ cancellation        │
│ crash recovery      │
└──────────┬──────────┘
           │
           ▼
    durable local disk
```

Tay can be used in three ways:

- **Elixir library** — add `tay` from Hex and run the Engine inside your
  supervision tree.
- **Standalone container** — run Tay as infrastructure beside your application,
  without installing Elixir or Erlang on the host.
- **Python client** — execute Python tasks through the supported `tay-client`
  SDK while Tay owns scheduling, retries, persistence, and recovery.

The optional **Tay Dashboard** adds a Phoenix LiveView operational UI and is
also published as a ready-to-run container image.

> Tay is intentionally single-node and single-writer. It is designed for cases
> where durable background execution is needed without operating a separate
> database or distributed broker. It is not a replacement for a distributed
> multi-node message bus.

## Quick start with Docker

The easiest way to try Tay does not require Elixir or Erlang on the host.

Pull the standalone image:

```sh
docker pull ghcr.io/andriisydorenko1904/tay:0.13.1
```

For a ready-made application + Tay example:

```sh
docker compose -f examples/standalone/docker-compose.yml up --build
```

The Tay container owns durable state at `/var/lib/tay`. Applications and
language workers communicate with it through the shared `/run/tay` Unix socket.

Restarting or replacing the Tay container does not discard jobs as long as the
data volume is preserved.

Want the operational UI as well?

```sh
docker compose -f examples/dashboard/docker-compose.yml up --build
```

Then open:

```text
http://localhost:4000/tay
```

The same image contains the optional dashboard. Enable it with
`ENABLE_DASHBOARD=true`:

```sh
docker pull ghcr.io/andriisydorenko1904/tay:0.13.1
```

## Why Tay?

A durable background-job system needs somewhere to keep pending, running,
scheduled, and retryable work.

Many systems delegate that responsibility to DB, Redis, or a message
broker.

Tay takes a different approach:

**the job engine includes its own crash-safe local store.**

That makes Tay useful when you want:

- durable queues without provisioning a separate database or broker;
- retries, scheduling, cron, cancellation, and queue concurrency in one runtime;
- recovery of durable job state after process or container restarts;
- a small infrastructure footprint for a single-machine or single-node deployment;
- Elixir-native embedding when the application is already written in Elixir;
- a standalone container when the application is written in another language;
- Python workers without moving persistence and orchestration into Python.

Tay provides **at-least-once execution**. External effects must therefore be
idempotent or reconciled by the application.

## Architecture

Tay separates durable orchestration from application code.

When running standalone, Tay can be treated as a small infrastructure
component:

```text
┌──────────────────────┐
│ Application / Worker │
│                      │
│ Python / other       │
│ local runtime        │
└──────────┬───────────┘
           │
           │ Unix socket
           │
           ▼
┌──────────────────────┐
│         Tay          │
│                      │
│ durable job engine   │
│ queues               │
│ schedules / cron     │
│ retries              │
│ cancellation         │
│ recovery             │
└──────────┬───────────┘
           │
           ▼
    persistent volume
```

Unlike a network message broker, worker execution is deliberately local: Tay
uses a Unix-domain socket for worker registration and dispatch. An opt-in,
loopback-bound gRPC producer API is available for enqueue/status/cancel/result
operations; see [`docs/protocol.md`](docs/protocol.md).

This keeps the single-node trust and failure model explicit while allowing the
Engine to be packaged and operated independently from application workers.

For Elixir applications, no service boundary is required at all. The same
Engine can run directly inside the application's supervision tree.

## Elixir integration

Use Elixir 1.20 and Erlang/OTP 29 with a C11 compiler (`cc`) available when
building.

Add Tay to your application's Mix dependencies:

```elixir
defp deps do
  [
    {:tay, "~> 0.13.1"}
  ]
end
```

Or use the local checkout:

```elixir
{:tay, path: "../tay"}
```

Then run:

```sh
mix deps.get
mix compile
```

For a development run, choose a dedicated absolute directory and initialize it
once. Initialization refuses existing history and is never a repair command:

```sh
export TAY_DATA_DIR="$PWD/var/tay"
mix tay.storage.init --data-dir "$TAY_DATA_DIR" --durability write
```

Define a worker with a stable key:

```elixir
defmodule MyApp.HelloWorker do
  use Tay.Worker, key: "hello.v1", queue: :default

  @impl true
  def perform(%Tay.Job{args: %{"name" => name}}) do
    IO.puts("Hello, #{name}!")
    :ok
  end
end
```

Add Tay to your application's supervisor.

The `:write` mode below is for development only and has no power-loss
durability guarantee:

```elixir
children = [
  Tay.child_spec(
    data_dir: System.fetch_env!("TAY_DATA_DIR"),
    durability: :write,
    workers: %{"hello.v1" => MyApp.HelloWorker},
    queues: [default: 2]
  )
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Explicit initialization remains the default.

An embedding application may instead pass:

```elixir
initialize: :if_missing
```

to `Tay.child_spec/1`.

That option only initializes a genuinely missing storage root before the normal
full recovery path. It never repairs, replaces, truncates, or reinitializes
existing storage.

Once the Engine is ready, submit and inspect a job:

```elixir
%{state: :ready} = Tay.status()

{:ok, intent} =
  MyApp.HelloWorker.new(%{"name" => "Ada"})

{:ok, job} =
  Tay.insert(intent)

{:ok, current} =
  Tay.get_job(job.id)

IO.inspect(current.state)
```

List and summarize jobs through the bounded public inspection API:

```elixir
{:ok,
 %{
   jobs: jobs,
   total_count: total,
   previous_cursor: previous,
   next_cursor: next,
   last_cursor: last
 }} =
  Tay.jobs(
    states: [:retryable, :discarded],
    queues: [:default],
    limit: 50
  )

{:ok, counts} = Tay.stats()
{:ok, queues} = Tay.queues()
```

The separately published optional `tay_dashboard` package provides an official
Phoenix LiveView UI for these APIs.

It lives in this repository under the
[`dashboard/` project](https://github.com/AndriiSydorenko1904/tay/tree/v0.13.1/dashboard),
but Phoenix, LiveView, and Plug are not dependencies of the core `tay` package.

See its
[README](https://github.com/AndriiSydorenko1904/tay/blob/v0.13.1/dashboard/README.md)
for installation, router mounting, and access-control guidance.

Keep the original intent until an insertion outcome is known. A lost reply may
follow a durable write; reconcile by job ID or resubmit the *same* intent,
never a newly generated ID.

External worker effects may run again after a crash, so make them idempotent or
reconcile them in the application.

## Python integration

Python is a first-class external-worker integration.

Tay remains responsible for:

- durable job state;
- queues;
- scheduling;
- retries;
- cancellation;
- crash recovery.

Python processes execute application code.

When Tay is embedded in Elixir, the Engine starts a local Unix-domain socket
automatically.

When Tay runs as a standalone container, mount the shared socket volume into
the Python worker container.

The same `tay-client` SDK is used in both cases.

Install it from PyPI:

```sh
python -m pip install tay-client
```

Or from this checkout:

```sh
python -m pip install ./clients/python
```

Then define and submit tasks:

```python
from tay import Tay

tay = Tay(capacity=4)

@tay.task(name="billing.capture.v1")
def capture(invoice_id: str) -> dict:
    return {"invoice_id": invoice_id}

async def submit() -> None:
    await tay.start()

    job = await capture.enqueue(
        "inv-42",
        submission_id="capture:inv-42",
    )

    print(await job.status())
```

This gives Python applications a simple split:

```text
Python
  │
  │ execute application code
  ▼
tay-client
  │
  │ Unix socket
  ▼
Tay
  │
  ├── persistence
  ├── queues
  ├── scheduling
  ├── retries
  └── recovery
```

The Python application does not need to implement its own durable queue or
persistence layer.

### Python schedules

The Python client accepts standard five-field Unix cron expressions.

Schedules use UTC by default; pass a fixed numeric offset when needed.

The API accepts:

```text
catch_up="latest"
catch_up="all"
```

and defaults to:

```text
overlap="skip"
```

Example:

```python
# At 08:00 on weekdays in UTC+02.
await tay.schedule(
    "billing.capture.v1",
    cron="0 8 * * 1-5",
    timezone="+02",
)

# Start in ten minutes, then repeat every fifteen minutes.
await tay.every(
    "billing.capture.v1",
    minutes=15,
    delay=600,
)
```

Use `start_at=<UTC milliseconds>` for an absolute first run instead of
`delay`; those options cannot be combined.

The listener schedule registry belongs to the live execution generation. A
connected Python client retains successful declarations and recreates them as
part of every reconnect, including after compaction. A client-process restart
still requires application startup to declare schedules again. Missed-time
catch-up and enforced overlap policies are not yet implemented. Once a timer is
due, temporary admission pressure delays that occurrence instead of dropping
it; its deterministic job ID makes retries idempotent.

Worker dispatch remains local-only; there is no multi-host worker protocol.
The optional gRPC producer listener is TCP and must be explicitly enabled with
`grpc_port`. It defaults to loopback; non-loopback bindings require mTLS server
and client CA certificates. See the protocol contract for configuration.

See the [protocol contract](docs/protocol.md) for discovery, security, request
types, and result retention.

## Standalone container

The release workflow publishes a self-contained Linux image for `amd64` and
`arm64`:

```text
ghcr.io/andriisydorenko1904/tay:0.13.1
```

It includes the Erlang VM and Tay runtime.

The host therefore needs Docker or another OCI runtime, not Elixir or Erlang.

Pull it directly:

```sh
docker pull ghcr.io/andriisydorenko1904/tay:0.13.1
```

A typical non-Elixir deployment runs the image beside an application worker:

```text
┌────────────────────┐
│ Application worker │
└─────────┬──────────┘
          │
          │ /run/tay
          │
┌─────────▼──────────┐
│    Tay container   │
│                    │
│ durable job engine │
└─────────┬──────────┘
          │
          │ /var/lib/tay
          ▼
    persistent volume
```

The application and Tay share only the `/run/tay` socket volume.

Durable state belongs on:

```text
/var/lib/tay
```

The included example starts both services:

```sh
docker compose -f examples/standalone/docker-compose.yml up --build
```

The container is:

- single-node;
- single-writer;
- non-root;
- compatible with a read-only root filesystem.

The Tay container does not execute user job code.

Deleting its data volume deletes Tay's durable state.

Deleting its socket volume does not.

See the [standalone runtime guide](docs/standalone.md) for volumes,
permissions, configuration, health checks, restart behavior, and deployment
details.

## Dashboard

Tay Dashboard is an optional operational web UI built with Phoenix LiveView.

The `tay` image contains Tay core and the small Phoenix host in one release.
The web endpoint is disabled by default and enabled with:

```text
ENABLE_DASHBOARD=true
```

Start the repository example:

```sh
docker compose -f examples/dashboard/docker-compose.yml up --build
```

Then open:

```text
http://localhost:4000/tay
```

The example binds only to host loopback and leaves optional Basic
authentication disabled.

The single Tay container owns the Store and optionally serves the dashboard.

See the
[complete dashboard container guide](dashboard/guides/docker.md)
for configuration, optional Basic authentication, reverse-proxy guidance,
persistence, and upgrade rules.

## Project status

Tay is currently a public preview with a deliberately constrained,
target-validated operating profile.

The storage format, recovery behavior, supported filesystems, and durability
requirements are documented explicitly.

Production `:sync` requires Linux and an explicitly validated supported local
filesystem.

Before production use, read:

- [Operations](docs/operations.md)
- [Storage contract](docs/storage.md)
- [Compatibility](docs/compatibility.md)
- [Standalone runtime](docs/standalone.md)
- [Worker protocol](docs/protocol.md)

## Operate safely

Production `:sync` requires Linux, an explicitly validated supported local
filesystem, and:

```elixir
validated_filesystem: true
```

macOS supports explicit development `:write` only.

Tay evaluates obsolete history automatically through bounded-retention,
online Store-v2 compaction. Candidate construction keeps admission and execution
live; a fenced, validated switch publishes the replacement epoch. Initial Store-v1
adoption still drains and recovers once.

It has no:

- automatic tail repair;
- live backup;
- exactly-once external effects.

A corrupt or unsupported history refuses writable startup and preserves the
evidence.

Do not delete individual log files to recover capacity.

See [operations](docs/operations.md) for initialization, inspection, cold
backup/restore, and incident response.

The [storage contract](docs/storage.md) describes persistent formats and
recovery.

[Compatibility](docs/compatibility.md) covers supported platforms, upgrade
boundaries, and finite release limits.

The [standalone guide](docs/standalone.md) covers the official Docker/OCI
runtime.

## License

The Tay engine is source-available under the Elastic License 2.0.

Internal use, including use inside an ordinary commercial SaaS product, is
free.

The license does not permit offering Tay itself, or a substantial set of its
functionality, to third parties as a hosted or managed service.

Commercial terms for that use are available separately; see
[commercial licensing](COMMERCIAL-LICENSING.md).

The separately distributed Python client is licensed under MIT.
