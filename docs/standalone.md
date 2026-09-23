# Standalone runtime

Tay has two deployment modes. Elixir applications continue to install the Hex
package and supervise `Tay.child_spec/1`. Non-Elixir applications may run the
official OCI image and connect a language client to its Executor Protocol v1
Unix socket. The standalone runtime is only a small OTP host around the same
Engine, scheduler, storage implementation, and recovery rules as the library.

```text
Python or another client -> /run/tay/tay.sock -> Tay OTP release
                                                   |
                                                   v
                                             /var/lib/tay
```

## Configuration

The image runs as UID/GID `10001:10001` and accepts:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TAY_DATA_DIR` | `/var/lib/tay` | Authoritative durable Store root. |
| `TAY_SOCKET_PATH` | `/run/tay/tay.sock` | Executor Protocol v1 UDS path. |
| `TAY_INITIALIZE_IF_MISSING` | `false` | `true`, `TRUE`, or `1` permits initialization only when the Store root is genuinely absent. |

Malformed explicit values fail startup. The socket must be absolute, at most
100 bytes, and outside the data directory. The socket is created with mode
`0660` so a worker can use a shared group where the deployment platform
supports it.

Tay deliberately does not interpret a pre-existing empty directory as a
missing Store. Docker creates a named-volume mount root before the process
starts, so mount the volume at `/var/lib/tay` and set
`TAY_DATA_DIR=/var/lib/tay/store`, as in
[`examples/standalone/docker-compose.yml`](../examples/standalone/docker-compose.yml).
The image creates both volume targets with ownership `10001:10001`; an empty
Docker named volume inherits that ownership and does not need a root init
container. Bind mounts and volume drivers that preserve different ownership
must be prepared for UID/GID 10001 by the operator.

The image supports a read-only root filesystem. Its only writable locations
are the durable data volume, the ephemeral socket volume, and `/tmp`. It drops
no privileges at startup and never runs as root.

## Run with Compose

From the repository root:

```sh
docker compose -f examples/standalone/docker-compose.yml up --build
```

The worker example installs the stdlib-only Python client and advertises an
`example.echo.v1` task. Production workers should pin a `tay-client` version
compatible with the image's protocol version.

The health check succeeds only when the Engine reports `ready` and a connection
can be opened to the configured UDS. A live BEAM process alone is not healthy.

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
external worker processes do that over the existing UDS protocol.

## Dashboard-enabled distribution

The separate `tay-dashboard` OCI image is built from the same standalone host
and adds the `tay_dashboard` package plus a minimal Phoenix endpoint. It starts
one Engine and exposes both `/run/tay/tay.sock` and the web UI at `/tay`.
Application-level authentication is optional. It is a replacement for
the headless image, not a sidecar.

```sh
docker compose -f examples/dashboard/docker-compose.yml up --build
```

Both images use the same data and socket volume contracts. Never start one of
each against the same data volume. See the
[dashboard container guide](../dashboard/guides/docker.md) for its network
boundary, optional credentials, HTTP configuration, and Compose example.
