# Standalone runtime

Tay has two deployment modes. Elixir applications continue to install the Hex
package and supervise `Tay.child_spec/1`. Non-Elixir applications may run the
official OCI image and connect a language client via HTTP/JSON or the local
Executor Protocol v1 Unix socket. The standalone runtime is only a small OTP host around the same
Engine, scheduler, storage implementation, and recovery rules as the library.

```text
Python producer/worker -> HTTPS :8080 ─┐
Python local worker   -> Unix socket ──┴─> Tay OTP release -> /var/lib/tay
```

## Configuration

The image runs as UID/GID `10001:10001` and accepts:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TAY_DATA_DIR` | `/var/lib/tay` | Authoritative durable Store root. |
| `TAY_SOCKET_PATH` | `/run/tay/tay.sock` without HTTP; disabled with HTTP | Executor Protocol v1 UDS path; explicitly set a path to enable both transports, or `off` to disable UDS. |
| `TAY_HTTP_PORT` | unset | Enables the Bandit HTTP/JSON API for producers and remote workers. |
| `TAY_HTTP_IP` | `127.0.0.1` | Listener IP; non-loopback requires mTLS. |
| `TAY_HTTP_TLS_{CERTFILE,KEYFILE,CACERTFILE}` | unset | Absolute PEM paths for server certificate, private key and client CA. Set all three together. |
| `TAY_INITIALIZE_IF_MISSING` | `false` | `true`, `TRUE`, or `1` permits initialization only when the Store root is genuinely absent. |
| `TAY_DEFAULT_QUEUE_CONCURRENCY` | `10` | Maximum concurrently executing jobs in the standalone `default` queue (`1..65536`). Actual execution is also bounded by registered worker capacity. |
| `TAY_CALLER_TIMEOUT_MS` | `5000` | Maximum time an admitted Engine call may wait for its reply. A timeout after submission is reported as `unknown_outcome`; reconcile with the same job ID. |
| `TAY_GROUP_COMMIT_INTERVAL_MS` | `0` | Durable enqueue group-commit window in milliseconds (`0..1000`). `0` preserves immediate fsync behavior. Invalid values stop startup. |
| `TAY_RATE_LIMITS` | `{}` | JSON queue/task execution limits; see [operations](operations.md#execution-rate-limits). Monotonic fixed windows reset on Engine restart. |
| `TAY_CHECKPOINT_INTERVAL_MS` | `60000` | Periodic crash-safe Store-v2 semantic checkpoint interval in milliseconds (`0..4294967295`). `0` disables it. Automatic checkpoints run after new durable events even with active jobs, capture live state at a durable frontier without replaying old journal segments, and recovery replays the snapshot plus its tail. |
| `TAY_MAX_STATE_BYTES` | `268435456` | Conservative in-memory byte budget for active jobs. Accepts bytes or an integer with `KB`, `MB`, or `GB`, for example `5GB`. These suffixes use binary multiples. |
| `TAY_TERMINAL_RETENTION` | `24h` | Initial retention for terminal jobs. Positive durations use `m`, `h`, or `d`, for example `30m`, `1h`, `24h`, or `7d`. The Dashboard/API may use zero as a one-shot full terminal-history purge, after which the persisted retention is `1h`. After a successful Dashboard compaction, the persisted Dashboard value takes priority on restart. |
| `TAY_ENABLE_DASHBOARD` | `false` | Set to `true`, `TRUE`, or `1` to serve the bundled dashboard. |
| `TAY_DASHBOARD_HOST` | `localhost` | Public hostname for dashboard URL and LiveView origin checks. |
| `TAY_DASHBOARD_PORT` | `4000` | Dashboard listener port. |
| `TAY_DASHBOARD_USERNAME` | unset | Optional HTTP Basic Auth username; requires password. |
| `TAY_DASHBOARD_PASSWORD` | unset | Optional HTTP Basic Auth password; requires username. |
| `TAY_DASHBOARD_SECRET_KEY_BASE` | unset | At least 64 random bytes; required when dashboard is enabled. |

`TAY_DURABILITY` is intentionally not an environment setting. The standalone
runtime pins `durability: :sync` and validates the filesystem before writing;
an unnoticed override to `:write` would weaken the production durability
contract. Embedded Elixir applications can configure their Engines explicitly,
subject to Tay's production validation.

An unset or empty `TAY_SOCKET_PATH` uses automatic transport selection.
Malformed explicit values fail startup. The socket must be absolute, at most
100 bytes, and outside the data directory. The socket is created with mode
`0660` so a worker can use a shared group where the deployment platform
supports it. Standalone uses the same path resolver as the embedded Engine:
outside the container, an absent `/run/tay` falls back to XDG, TMPDIR, or the
per-UID `/tmp` directory. The Python SDK discovers `/run/tay/tay.sock` from the mounted
`/run/tay` directory without a `TAY_SOCKET_PATH` setting. Keep the shared socket
volume mounted into both containers (read-only in the worker); network sharing
alone does not make Unix socket files visible across containers.

Concurrent persistent commands are flushed when the global batch reaches
`max_events` or its `interval_ms` expires, whichever happens first. They are
written in arrival order and acknowledged together only after their batch fsync
succeeds. Batching does not change recovery, capacity accounting, or failure
semantics; a write/fsync error fails the generation without returning success
for that batch. Embedded Engines use global
`journal: [batch: [max_events: n, interval_ms: milliseconds]]` configuration.
The legacy `:group_commit_interval_ms` Engine option remains accepted.
`durability: :write` remains immediate.

`TAY_MAX_STATE_BYTES` uses binary multipliers: `KB` is 1,024 bytes, `MB` is
1,024 KB, and `GB` is 1,024 MB. For example, `5GB` is `5_368_709_120` bytes.
A value without a suffix is interpreted as bytes for backward compatibility.

Active-job and terminal-history counts are informational and have no configured
maximum. `TAY_MAX_JOBS` and `TAY_MAX_TERMINAL_JOBS` are legacy variables and are
ignored. Active payloads use one `TAY_MAX_STATE_BYTES` budget; structural
complexity is included through the retained job's flat BEAM heap size rather
than a separate item limit. The former `TAY_MAX_STATE_NODES` variable is ignored.
Terminal history is removed only by time-based compaction.

Python HTTP producers and workers need only the HTTP(S) address. Set
`TAY_HTTP_PORT` to run without a Unix socket; an explicit `TAY_SOCKET_PATH`
enables both transports. `TAY_SOCKET_PATH=off` is also supported. For an HTTP-only Compose deployment use `docker compose up tay`;
the example's `worker` service demonstrates the optional local socket mode.
The example still declares an unused socket volume in HTTP-only mode; neither
the Engine nor Python HTTP clients require a socket in that configuration.

The optional HTTP API runs inside the same Engine. Plaintext is permitted only
on loopback; non-loopback binds require the three TLS files and verify client
certificates. Mount certificates read-only, ensure UID `10001` can read them,
and match the server certificate SAN to the client's DNS name or IP. Legacy
`TAY_GRPC_*` settings fail startup rather than silently disabling the old API.

Tay deliberately does not interpret a pre-existing empty directory as a
missing Store. Docker creates a named-volume mount root before the process
starts, so mount the volume at `/var/lib/tay` and set
`TAY_DATA_DIR=/var/lib/tay/store`, as in
[`compose.yml`](../compose.yml).
The image creates both directory targets with ownership `10001:10001`; an empty
Docker named volume inherits that ownership and does not need a root init
container. Bind mounts and volume drivers that preserve different ownership
must be prepared for UID/GID 10001 by the operator.

The image supports a read-only root filesystem. Its only writable locations
are the durable data volume, the optional ephemeral socket volume, and `/tmp`. It drops
no privileges at startup and never runs as root.

## Run with Compose

From the repository root:

```sh
TAY_IMAGE=tay:local docker compose up --build
```

This starts Tay only. To include the example local socket worker, use
`TAY_IMAGE=tay:local docker compose --profile local-worker up --build`.
Compose lists settings needed for this deployment example; the table above
lists all supported standalone environment settings.

Set `TAY_ENABLE_DASHBOARD=true` in the same Compose deployment to enable the
dashboard. The HTTP API is opt-in; to expose it outside the container, set
`TAY_HTTP_PORT=8080`, `TAY_HTTP_IP=0.0.0.0`, and
`TAY_HTTP_HOST_BIND=0.0.0.0`; mount the three TLS files read-only and set their
`TAY_HTTP_TLS_*` paths. Without mTLS the non-loopback bind is rejected. Start
only the `tay` Compose service for HTTP-only use. To retain the local socket
worker too, explicitly set `TAY_SOCKET_PATH=/run/tay/tay.sock` on the Tay
service. Compose environment overrides must be added to the service environment.

The worker example installs the stdlib-only Python client and advertises an
`example.echo.v1` task. Production workers should pin a `tay-client` version
compatible with the image's protocol version.

For a worker on another host, run Tay without a socket and mount a directory
containing the server certificate, its key, and the CA that signs client
certificates. For example, after creating the `taydata` volume:

```sh
docker run -d --name tay \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m,uid=10001,gid=10001,mode=0700 \
  --cap-drop ALL --security-opt no-new-privileges \
  -p 8080:8080 \
  -e TAY_DATA_DIR=/var/lib/tay/store \
  -e TAY_INITIALIZE_IF_MISSING=true \
  -e TAY_SOCKET_PATH=off \
  -e TAY_HTTP_PORT=8080 -e TAY_HTTP_IP=0.0.0.0 \
  -e TAY_HTTP_TLS_CERTFILE=/etc/tay/tls/server.pem \
  -e TAY_HTTP_TLS_KEYFILE=/etc/tay/tls/server.key \
  -e TAY_HTTP_TLS_CACERTFILE=/etc/tay/tls/client-ca.pem \
  --mount type=volume,src=taydata,dst=/var/lib/tay \
  --mount type=bind,src=/absolute/path/to/tls,dst=/etc/tay/tls,readonly \
  ghcr.io/andriisydorenko1904/tay:1.8.0-rc3
```

Create the volume with `docker volume create taydata`. Replace the TLS source
path, ensure UID `10001` can read the mounted files, and provision client
certificates separately for workers. On later starts, set
`TAY_INITIALIZE_IF_MISSING=false`. Restrict the published port to the intended
worker network. The Python connection example is in the
[Python client guide](https://github.com/AndriiSydorenko1904/tay/tree/v1.3.6/clients/python).

The health check succeeds when the Engine reports `ready` or is performing a
normal online checkpoint in `compacting/preparing` or `compacting/switching`,
and the selected transport is available (HTTP if the socket is disabled,
otherwise the UDS).
A live BEAM process alone is not healthy. The image grants startup a 15-minute
health-check grace period, matching the default bounded recovery deadline;
steady-state failures still use the ordinary 12 attempts at five-second
intervals.

## Persistence and operations

`/var/lib/tay` is persistent state. Back it up using Tay's documented storage
procedure; copying a live writable directory is not a supported backup.
Deleting the data volume deletes durable job history. `/run/tay` is runtime IPC
state only and may be recreated on every deployment.

Tay remains single-node and single-writer. Never attach one data volume to two
Tay containers. It provides at-least-once execution, performs full recovery on
restart, and fails closed on invalid, partial, corrupt, or unsupported storage.
It does not automatically repair or truncate evidence. Use a local Linux
filesystem whose durability properties have been validated for the workload.

The standalone image is not distributed Tay and does not run user job code;
external worker processes do that over HTTP/JSON or the local UDS protocol.

## Optional dashboard

The same `tay` OCI image bundles the dashboard from the `tay` package and a minimal
Phoenix endpoint. Set `TAY_ENABLE_DASHBOARD=true` to expose both
`/run/tay/tay.sock` and the web UI at `/tay`. Application-level authentication
is optional. No second container or image is required.

```sh
TAY_IMAGE=tay:local TAY_ENABLE_DASHBOARD=true docker compose up --build
```

The headless and dashboard-enabled modes use the same data and transport
contracts. See the
[dashboard container guide](dashboard-container.md) for its network
boundary, optional credentials, HTTP configuration, and Compose example.

The CI container smoke test runs Tay and the Python worker without
`TAY_SOCKET_PATH`, with a read-only socket mount in the worker. It replaces the
Tay container while keeping the worker running, checks a recovered result, and
executes a new job through the reconnected worker. The HTTP-only smoke test
sets only `TAY_HTTP_PORT` and verifies that no Unix socket is created.


## Read-only readiness and client diagnostics

`GET /health` returns a bounded `{ "type": "health", "state": "ready" }`
response (or `compacting` during the accepted online preparation/switch phases).
An unavailable/non-ready Engine returns HTTP 503. The route uses the listener's
existing loopback/mTLS policy and contains no jobs or private Engine state.
Use `tay doctor --http-url ORIGIN --json` or `tay doctor --socket-path PATH`
from the Python SDK to diagnose the configured listener without creating jobs.

The included `examples/standalone/worker.py` selects `TayHTTPWorker` when
`TAY_HTTP_URL` is set, and a socket worker otherwise. Both use the same image
entry point and task declarations; the container smoke test exercises HTTP CLI
execution, result waiting, diagnostics and clean SIGTERM shutdown.
