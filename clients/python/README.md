# Tay Python SDK

`tay` is the stdlib-only Protocol v1 producer and worker client for a local Tay
Unix-domain socket. `Tay()` needs no socket setting: it uses the same discovery
contract as the Elixir Engine (explicit path, `TAY_SOCKET_PATH`, XDG runtime,
`TMPDIR`, then `/tmp/tay-<uid>`). It is intentionally a separately installable
package:

```sh
python -m pip install tay-client
```

## gRPC producer

For a TCP gRPC producer, enable the Engine's `grpc_port` and install the
optional runtime dependency:

```sh
python -m pip install 'tay-client[grpc]'
```

`TayGrpc` is an async producer-only client. It supports `enqueue`, job status,
cancellation, and result retrieval; workers and schedules remain on the local
Protocol v1 socket.

```python
from tay import TayGrpc

async with TayGrpc("127.0.0.1:50051") as tay:
    job = await tay.enqueue("reports.rebuild.v1", {"report_id": "42"})
    result = await job.result()
```

For a Tay server on another host, configure mTLS on the Engine and supply a CA
certificate, client certificate chain, and client private key:

```python
async with TayGrpc(
    "tay.example:50051",
    tls_ca_file="/etc/tay/server-ca.pem",
    tls_cert_file="/etc/tay/client.pem",
    tls_key_file="/etc/tay/client.key",
) as tay:
    job = await tay.enqueue("reports.rebuild.v1", {"report_id": "42"})
```

The Python client can also load those three credentials from one encrypted
PKCS#12 file. Install `tay-client[grpc-pkcs12]` and export a bundle containing
the client key, client certificate, and trusted CA certificate:

```sh
openssl pkcs12 -export -inkey client.key -in client.pem \
  -certfile ca.pem -out client.p12
```

OpenSSL prompts for a bundle password. The CA private key must not be included.

```python
async with TayGrpc(
    "10.0.0.5:50051",
    tls_pkcs12_file="/etc/tay/client.p12",
    tls_pkcs12_password="bundle-password",
) as tay:
    job = await tay.enqueue("reports.rebuild.v1", {"report_id": "42"})
```

Provide the password through your secret manager rather than hard-coding it.
`TayGrpc` rejects non-loopback targets unless complete mTLS credentials are given.
The server certificate must match the target hostname (or IP address). Keep
private keys protected and restrict network access to the gRPC port. The
loopback endpoint may still be used without TLS on the same host.

From a Tay source checkout, use `python -m pip install ./clients/python`.

Create a `Tay(mode="client")` producer, or a `Tay(mode="worker")` process that
only executes registered tasks. The SDK sends JSON-object arguments and bounded
JSON results; it does not serialize arbitrary Python objects.

The producer surface is asynchronous: `enqueue`, `JobHandle.status()`,
`JobHandle.result()`, and `JobHandle.cancel()` map directly to the currently
supported Protocol v1 requests. Use a stable `submission_id` when retrying an
enqueue whose connection outcome is unknown.

Tasks declared before `await tay.start()` are advertised during the handshake.
For a long-running worker that adds or removes capabilities later, explicitly
sync the change:

```python
@tay.task(name="reports.rebuild.v1")
def rebuild(report_id: str) -> dict:
    return {"report_id": report_id}


await tay.register_tasks(rebuild)
# ... stop accepting new work for this task
await tay.unregister_tasks(rebuild)
```

Both changes are retained as desired capability state and reconciled on the
next connection. `client` mode cannot register task capabilities.

## Schedules

`schedule()` uses the five-field Unix cron form (minute, hour, day of month,
month, day of week). Its default timezone is `+00`; pass a fixed UTC offset
such as `+02`, `-05`, or `+05:30` when the schedule should be evaluated in a
different local clock. The API accepts `catch_up="latest"` (default) or
`catch_up="all"`, and defaults to `overlap="skip"`.

```python
# Every weekday at 08:00 in UTC+02.
await tay.schedule(
    "reports.rebuild.v1",
    cron="0 8 * * 1-5",
    timezone="+02",
    catch_up="latest",
)

# First run in ten minutes, then every fifteen minutes.
await tay.every("reports.rebuild.v1", minutes=15, delay=600)
```

Use `start_at=<UTC milliseconds>` instead of `delay` when the first occurrence
has an absolute timestamp. The two options are mutually exclusive. Schedule
creation, execution, and cancellation work against the current listener
generation. The client retains successful declarations in memory and replays
them during every reconnect, so compaction and Engine restart do not remove
schedules while the client remains alive. Application startup must declare
them again after a client-process restart. Missed-time catch-up and enforced
overlap policies are still pending.

Run a dedicated worker module with:

```sh
tay-worker myapp.jobs
```

The imported module must create exactly one `Tay(mode="worker")` instance and
register its tasks. Pass `socket_path=` or set `TAY_SOCKET_PATH` only to override
automatic discovery. See the repository README for the current durable-result/
scheduling compatibility boundary.

## License

The `tay-client` Python package is licensed under the MIT License. The Tay
engine is distributed separately under the Elastic License 2.0.
