# Dashboard-enabled container

The dashboard image is the operational Tay runtime with the optional web UI
included. It owns the Store and starts exactly one Tay Engine. It also exposes
the same Executor Protocol v1 Unix socket as the headless image, so external
workers connect in the same way.

```text
browser -> HTTP :4000 -> Phoenix LiveView -> Tay public API
                                               |
worker  -> /run/tay/tay.sock -> Executor API -> Engine -> /var/lib/tay/store
```

It is not a dashboard sidecar. Never attach both `tay` and `tay-dashboard`
containers to one `/var/lib/tay` volume: Tay is deliberately single-writer.

## Compose quick start

The repository example starts the dashboard-enabled runtime and a Python
worker:

```sh
docker compose -f examples/dashboard/docker-compose.yml up --build
```

Open <http://localhost:4000/tay>. The example binds HTTP to host loopback and
does not enable application-level authentication.
Set `TAY_DASHBOARD_HTTP_PORT` to change only the published host port in this
Compose example; the container continues listening on port `4000`.

`TAY_DASHBOARD_SECRET_KEY_BASE` remains required because Phoenix uses it to
sign browser sessions. Supply a random value without editing the Compose file:

```sh
export TAY_DASHBOARD_SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker compose -f examples/dashboard/docker-compose.yml up -d
```

To additionally enable built-in HTTP Basic authentication, provide both
credentials:

```sh
export TAY_DASHBOARD_USERNAME=operator
export TAY_DASHBOARD_PASSWORD='replace-with-a-long-random-password'
docker compose -f examples/dashboard/docker-compose.yml up -d
```

Pin `TAY_DASHBOARD_IMAGE` to an immutable release tag in production. The
dashboard image replaces the `tay` service from the headless example; workers
continue sharing only the `taysocket` volume.

## Run without Compose

Create the two volumes once:

```sh
docker volume create taydata
docker volume create taysocket
```

Then start the release:

```sh
docker run --name tay-dashboard \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m,uid=10001,gid=10001,mode=0700 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  -p 127.0.0.1:4000:4000 \
  -e TAY_DATA_DIR=/var/lib/tay/store \
  -e TAY_INITIALIZE_IF_MISSING=true \
  -e TAY_DASHBOARD_SECRET_KEY_BASE='replace-with-at-least-64-random-bytes------------------------' \
  -v taydata:/var/lib/tay \
  -v taysocket:/run/tay \
  ghcr.io/andriisydorenko1904/tay-dashboard:0.11.1
```

On subsequent starts, set `TAY_INITIALIZE_IF_MISSING=false`. Initialization is
only for a genuinely missing Store and is never a repair operation.

## Configuration

The dashboard image accepts every variable supported by the headless image,
plus the HTTP settings below.

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `TAY_DATA_DIR` | `/var/lib/tay` | no | Authoritative Store root. Use `/var/lib/tay/store` with a named volume. |
| `TAY_SOCKET_PATH` | `/run/tay/tay.sock` | no | Executor Protocol v1 Unix socket. |
| `TAY_INITIALIZE_IF_MISSING` | `false` | no | Initialize only a genuinely absent Store. |
| `TAY_DASHBOARD_HOST` | `localhost` | no | Public hostname accepted for LiveView origin checks; no scheme, port, or path. |
| `TAY_DASHBOARD_PORT` | `4000` | no | Container HTTP listen port. |
| `TAY_DASHBOARD_USERNAME` | none | no | Optional HTTP Basic authentication username; must be paired with the password. |
| `TAY_DASHBOARD_PASSWORD` | none | no | Optional HTTP Basic authentication password; must be paired with the username. |
| `TAY_DASHBOARD_SECRET_KEY_BASE` | none | yes | Random Phoenix signing secret of at least 64 bytes. |

Basic Auth is disabled when neither credential is set. Supplying only one, or
supplying a blank value, fails startup. Other invalid or missing required
configuration also fails startup. The HTTP listener binds all container
interfaces so Docker port publishing works;
`TAY_DASHBOARD_HOST` controls URL generation and LiveView origin validation,
not the bind address.

If users access the UI as `https://jobs.example.com/tay`, set
`TAY_DASHBOARD_HOST=jobs.example.com`. Keep the internal port at `4000` and let
the reverse proxy terminate TLS. For nonstandard public ports, configure the
proxy to preserve the browser `Host` header.

## Security boundary

The dashboard can display job arguments and perform Retry, Cancel, Pause, and
Resume operations. Treat network access to it as administrator access. The
default security boundary is the deployment network: the image publishes no
port by itself, and the Compose example binds HTTP only to `127.0.0.1`.

- Bind to `127.0.0.1` when accessing it locally.
- For remote access, prefer a private network, VPN, SSH tunnel, or trusted
  ingress. Terminate TLS before traffic crosses an untrusted network.
- Enable the built-in Basic Auth when deployment-level access control is not
  sufficient or when an additional protection layer is desired.
- Store the Phoenix secret and any optional credentials in the platform secret
  manager. Do not reuse the signing secret as the dashboard password.

The embedded Hex package intentionally does not impose authentication because
the host Phoenix application owns its identity and authorization policy.

## Persistence, health, and upgrades

`/var/lib/tay` is durable state; `/run/tay` is ephemeral worker IPC. Deleting
the socket volume is safe while Tay and workers are stopped. Deleting the data
volume deletes job history.

The OCI health check succeeds only after the Engine is ready and the Unix
socket accepts connections. The container smoke test separately exercises the
default unauthenticated HTTP page and its LiveView assets; host tests cover the
optional Basic Auth path.

Use the same cold backup and restore process as the headless runtime. Stop the
old container before starting a new image against its volume. Never use a
rolling deployment with two replicas sharing the Store.

## Choosing an image

Use `tay:<version>` when no UI is needed or the smallest possible runtime is
preferred. Use `tay-dashboard:<version>` when non-Elixir workers need the
official UI. In an existing Phoenix application, use the `tay_dashboard` Hex
package instead of either standalone web host.
