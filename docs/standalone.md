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
| `TAY_SOCKET_PATH` | `/run/tay/tay.sock` | Executor Protocol v1 UDS path; set `off` for HTTP-only operation. |
| `TAY_HTTP_PORT` | unset | Enables the Bandit HTTP/JSON API for producers and remote workers. |
| `TAY_HTTP_IP` | `127.0.0.1` | Listener IP; non-loopback requires mTLS. |
| `TAY_HTTP_TLS_{CERTFILE,KEYFILE,CACERTFILE}` | unset | Absolute PEM paths for server certificate, private key and client CA. Set all three together. |
| `TAY_INITIALIZE_IF_MISSING` | `false` | `true`, `TRUE`, or `1` permits initialization only when the Store root is genuinely absent. |
| `TAY_MAX_JOBS` | `100000` | Maximum simultaneously active jobs. Terminal history does not consume this budget. |
| `TAY_MAX_STATE_BYTES` | `268435456` | Conservative encoded-state byte budget for active jobs. |
| `TAY_MAX_STATE_NODES` | `2000000` | Conservative value-node budget for active jobs. |
| `TAY_MAX_TERMINAL_JOBS` | `5000` | Maximum retained completed, cancelled, and discarded jobs after pressure compaction. |
| `TAY_TERMINAL_RETENTION` | `24h` | Time retention for terminal jobs. Positive durations use `m`, `h`, or `d`, for example `30m`, `1h`, `24h`, or `7d`. |
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

Malformed explicit values fail startup. The socket must be absolute, at most
100 bytes, and outside the data directory. The socket is created with mode
`0660` so a worker can use a shared group where the deployment platform
supports it.
Python HTTP producers and workers need only the HTTP(S) address. Set
`TAY_SOCKET_PATH=off` together with `TAY_HTTP_PORT` to run without a Unix
socket. For an HTTP-only Compose deployment use `docker compose up tay`;
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
docker compose up --build
```

This starts Tay only. To include the example local socket worker, use
`docker compose --profile local-worker up --build`. Compose lists settings
needed for this deployment example; the table above lists all supported
standalone environment settings.

Set `TAY_ENABLE_DASHBOARD=true` in the same Compose deployment to enable the
dashboard. The HTTP API is opt-in; to expose it outside the container, set
`TAY_HTTP_PORT=8080`, `TAY_HTTP_IP=0.0.0.0`, and
`TAY_HTTP_HOST_BIND=0.0.0.0`; mount the three TLS files read-only and set their
`TAY_HTTP_TLS_*` paths. Without mTLS the non-loopback bind is rejected. To omit
the local worker socket as well, set `TAY_SOCKET_PATH=off` and start only the
`tay` Compose service.

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
  ghcr.io/andriisydorenko1904/tay:0.15.1
```

Create the volume with `docker volume create taydata`. Replace the TLS source
path, ensure UID `10001` can read the mounted files, and provision client
certificates separately for workers. On later starts, set
`TAY_INITIALIZE_IF_MISSING=false`. Restrict the published port to the intended
worker network. The Python connection example is in the
[Python client guide](https://github.com/AndriiSydorenko1904/tay/tree/v0.15.1/clients/python).

The health check succeeds only when the Engine reports `ready` and the selected
transport is available (HTTP if the socket is disabled, otherwise the UDS).
A live BEAM process alone is not healthy.

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
TAY_ENABLE_DASHBOARD=true docker compose up --build
```

The headless and dashboard-enabled modes use the same data and transport
contracts. See the
[dashboard container guide](dashboard-container.md) for its network
boundary, optional credentials, HTTP configuration, and Compose example.
