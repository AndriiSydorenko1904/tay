# Tay

Tay is an embedded, durable, single-node background-job engine for Elixir. It
stores an append-only job history locally, runs supervised Elixir workers, and
can dispatch stable task keys to local Python workers over a Unix socket. It
does not require a database or broker. This is a public preview with a
constrained, target-validated operating profile.

Tay can also run as a standalone production OCI image for non-Elixir
applications. This is an additional distribution mode around the same Engine;
the Hex dependency remains the normal Elixir installation. See the
[standalone runtime guide](docs/standalone.md) for its volumes, permissions,
configuration, health check, restart behavior, and Compose example.

When an operational web UI is required, the dashboard-enabled image combines
one Tay Engine, the same executor socket, and the optional LiveView dashboard.
It replaces the headless image rather than running as a sidecar. See the
[dashboard container guide](dashboard/guides/docker.md).

## Start locally

Use Elixir 1.20 and Erlang/OTP 29 with a C11 compiler (`cc`) available when
building. Add `{:tay, "~> 0.9.0"}` to your application's Mix dependencies, or
`{:tay, path: "../tay"}` for this checkout. Run `mix deps.get` and `mix compile`.

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

Add Tay to your application's supervisor. The `:write` mode below is for
development only and has no power-loss durability guarantee:

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

Explicit initialization remains the default. An embedding application may
instead pass `initialize: :if_missing` to `Tay.child_spec/1`. That option only
initializes a genuinely missing storage root before the normal full recovery
path; it never repairs, replaces, truncates, or reinitializes existing storage.

Once the Engine is ready, submit and inspect a job:

```elixir
%{state: :ready} = Tay.status()
{:ok, intent} = MyApp.HelloWorker.new(%{"name" => "Ada"})
{:ok, job} = Tay.insert(intent)
{:ok, current} = Tay.get_job(job.id)
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
  Tay.jobs(states: [:retryable, :discarded], queues: [:default], limit: 50)

{:ok, counts} = Tay.stats()
{:ok, queues} = Tay.queues()
```

The separately published optional `tay_dashboard` package provides an official
Phoenix LiveView UI for these APIs. It lives in this repository under the
[`dashboard/` project](https://github.com/AndriiSydorenko1904/tay/tree/v0.9.7/dashboard),
but Phoenix, LiveView, and Plug are not dependencies of the core `tay` package.
See its
[README](https://github.com/AndriiSydorenko1904/tay/blob/v0.9.7/dashboard/README.md)
for installation, router mounting, and access-control guidance.

Keep the original intent until an insertion outcome is known. A lost reply may
follow a durable write; reconcile by job ID or resubmit the *same* intent,
never a newly generated ID. External worker effects may run again after a
crash, so make them idempotent or reconcile them in the application.

## Local Python executors

The Engine starts a local Unix-domain socket automatically. The separate Python
SDK discovers the same path; neither side needs a socket setting for normal
local use. Install the SDK with `python -m pip install tay-client` (or
`python -m pip install ./clients/python` from this checkout), then:

```python
from tay import Tay

tay = Tay(capacity=4)

@tay.task(name="billing.capture.v1")
def capture(invoice_id: str) -> dict:
    return {"invoice_id": invoice_id}

async def submit() -> None:
    await tay.start()
    job = await capture.enqueue("inv-42", submission_id="capture:inv-42")
    print(await job.status())
```

### Python schedules

The Python client accepts standard five-field Unix cron expressions. Schedules
use UTC by default; pass a fixed numeric offset when needed. The API accepts
`catch_up="latest"` (default) or `catch_up="all"`, and defaults to
`overlap="skip"`.

```python
# At 08:00 on weekdays in UTC+02.
await tay.schedule("billing.capture.v1", cron="0 8 * * 1-5", timezone="+02")

# Start in ten minutes, then repeat every fifteen minutes.
await tay.every("billing.capture.v1", minutes=15, delay=600)
```

Use `start_at=<UTC milliseconds>` for an absolute first run instead of
`delay`; those options cannot be combined. The current listener schedule
registry belongs to the live execution generation. Durable schedule recovery,
restart catch-up, and enforced overlap policies are not yet implemented.

The socket is local only; there is no TCP listener or multi-host worker
protocol. See the [protocol contract](docs/protocol.md) for discovery, security,
request types, and result retention.

## Standalone container

The release workflow publishes a self-contained Linux image for `amd64` and
`arm64` as `ghcr.io/andriisydorenko1904/tay:0.9.7`. It includes the Erlang VM
and Tay runtime, so the host needs Docker (or another OCI runtime), not Elixir
or Erlang. Pull it directly with:

```sh
docker pull ghcr.io/andriisydorenko1904/tay:0.9.7
```

A typical non-Elixir deployment runs that image beside a language worker and
shares only the `/run/tay` socket volume. Durable state belongs on
`/var/lib/tay`. The included example starts both services:

```sh
docker compose -f examples/standalone/docker-compose.yml up --build
```

The container is single-node, single-writer, non-root, and compatible with a
read-only root filesystem. It does not execute user job code. Deleting its data
volume deletes Tay's durable state; deleting its socket volume does not.

### Standalone container with Dashboard

The dashboard distribution contains Tay core and a small Phoenix host
in one release. Start the repository example with:

```sh
docker compose -f examples/dashboard/docker-compose.yml up --build
```

Open <http://localhost:4000/tay>. The example binds only to host loopback and
leaves optional Basic authentication disabled. The image is
`ghcr.io/andriisydorenko1904/tay-dashboard:0.9.7`. It owns the Store, so never
run it beside the headless `tay` image on the same data volume.

See the [complete dashboard container guide](dashboard/guides/docker.md) for
configuration, optional Basic authentication, reverse-proxy guidance, persistence, and
upgrade rules.

## License

The Tay engine is source-available under the Elastic License 2.0. Internal use,
including use inside an ordinary commercial SaaS product, is free. The license
does not permit offering Tay itself, or a substantial set of its functionality,
to third parties as a hosted or managed service. Commercial terms for that use
are available separately; see
[commercial licensing](COMMERCIAL-LICENSING.md).

The separately distributed Python client is licensed under MIT.

## Operate safely

Production `:sync` requires Linux, an explicitly validated supported local
filesystem, and `validated_filesystem: true`. macOS supports explicit
development `:write` only. Tay evaluates obsolete history automatically through
bounded-retention, stop-the-world Store-v2 compaction. It has no automatic tail
repair, live backup, online compaction, or exactly-once external effects. A corrupt or unsupported
history refuses writable startup and preserves the evidence. Do not delete
individual log files to recover capacity.

Start with [operations](docs/operations.md) for initialization, inspection,
cold backup/restore, and incident response. The [storage contract](docs/storage.md)
describes persistent formats and recovery; [compatibility](docs/compatibility.md)
covers supported platforms, upgrade boundaries, and finite release limits. The
[standalone guide](docs/standalone.md) covers the official Docker/OCI runtime.
