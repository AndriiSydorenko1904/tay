# Tay Python SDK

`tay` is the stdlib-only Protocol v1 producer and worker client for a local Tay
Unix-domain socket. `Tay()` needs no socket setting: it uses the same discovery
contract as the Elixir Engine (explicit path, `TAY_SOCKET_PATH`, an existing
shared `/run/tay` directory, XDG runtime,
`TMPDIR`, then `/tmp/tay-<uid>`). It is intentionally a separately installable
package:

```sh
python -m pip install tay-client
```

## HTTP/JSON producer and remote worker

Enable the Bandit listener with `TAY_HTTP_PORT=8080` for a local deployment.
`TayHTTP` is an async producer client for enqueue, status, cancellation,
and result retrieval. `TayHTTPWorker` runs remote workers over the same HTTP
listener; schedules still use the local socket. To use schedules alongside
HTTP, explicitly enable a socket on the server as well.

```python
from tay import TayHTTP

async with TayHTTP("http://127.0.0.1:8080") as tay:
    job = await tay.enqueue("reports.rebuild.v1", {"report_id": "42"})
    status = await job.status()
```

`await job.result()` retrieves an available result; it does not wait for the
job to finish. Check `await job.status()` for completion first. If a result is
not ready, retrieval raises `ServerError` with code `result_not_ready`.

For remote access, set `TAY_HTTP_IP` to a non-loopback address and configure
the server certificate, key and client CA. Supply PEM client credentials:

```python
async with TayHTTP(
    "https://tay.example:8080",
    tls_ca_file="/etc/tay/server-ca.pem",
    tls_cert_file="/etc/tay/client.pem",
    tls_key_file="/etc/tay/client.key",
) as tay:
    job = await tay.enqueue("reports.rebuild.v1", {"report_id": "42"})
```

Remote targets require mTLS. The server certificate must match the target
hostname or IP address. Keep keys protected and restrict network access.
Alternatively install `tay-client[http-pkcs12]` and supply a single encrypted
bundle containing the client key, client certificate and trusted server CA:

```python
async with TayHTTP(
    "https://tay.example:8080",
    tls_pkcs12_file="/etc/tay/client.p12",
    tls_pkcs12_password="from-a-secret-manager",
) as tay:
    job = await tay.enqueue("reports.rebuild.v1", {"report_id": "42"})
```

The PEM key and certificate are extracted into a private temporary directory
only while Python loads them into its TLS context, then removed. The CA private
key must never be included in the bundle.

A worker can connect from another host without a shared filesystem:

```python
import asyncio
from tay import TayHTTPWorker

worker = TayHTTPWorker(
    "https://tay.example:8080",
    tls_pkcs12_file="/etc/tay/client.p12",
    tls_pkcs12_password="from-a-secret-manager",
)


@worker.task(name="reports.rebuild.v1", retries=3, backoff="exponential")
def rebuild(report_id: str) -> dict:
    return {"report_id": report_id, "rebuilt": True}


asyncio.run(worker.serve_forever())
```

The worker continuously long-polls, acknowledges starts and reports bounded
results. Keep it polling while executions run; session expiry causes in-flight
work to be retried at least once. Make external effects idempotent.

From a Tay source checkout, use `python -m pip install ./clients/python`.

Create a `Tay(mode="client")` producer, or a `Tay(mode="worker")` process that
only executes registered tasks. The SDK sends JSON-object arguments and bounded
JSON results; it does not serialize arbitrary Python objects.

The producer surface is asynchronous: `enqueue`, `JobHandle.status()`,
`JobHandle.result()`, and `JobHandle.cancel()` map directly to the currently
supported Protocol v1 requests. Use a stable `submission_id` when retrying an
enqueue whose connection outcome is unknown.

Choose job durability per submission with `durability="persistent"` (the
default) or `durability="volatile"`:

```python
durable = await tay.enqueue("reports.rebuild.v1", {}, durability="persistent")
ephemeral = await tay.enqueue("cache.warm.v1", {}, durability="volatile")
assert ephemeral.durability == "volatile"
```

Volatile jobs use Tay's normal execution, retry, cancellation, and accounting
paths, but never enter persistent storage and disappear with the Engine's
in-memory generation.

For `TayHTTPWorker`, tasks declared before `await worker.register()` are
advertised when it registers. `register()` only creates the remote worker
session; use `serve_forever()` to register and then continuously claim and
execute jobs.

Tasks declared before `await tay.start()` are advertised during the local
socket handshake.

## Decorated tasks

Use `@tay.task` for an ergonomic handler and producer API.  The default job
name is `<module>.<function_name>`; choose an explicit name for a public,
versioned contract.  The decorated object still calls the original function
locally, while `enqueue()` serializes its call arguments and submits the job.

```python
from tay import Tay

tay = Tay()


@tay.task
def refresh(account_id: str, force: bool = False) -> None:
    # default name: "my_module.refresh"
    ...


@tay.task(
    name="accounts.refresh.v1",
    retries=3,
    backoff="exponential",
    durability="volatile",
)
def public_refresh(account_id: str) -> None: ...


job = await refresh.enqueue("acct-42", force=True)
```

`retries`, `backoff`, and `durability` declared on either `Tay.task` or
`TayHTTPWorker.task` become defaults when the decorated task enqueues a job.
Pass an option such as `retries=0` to `task.enqueue()` to override a default for
one submission.

Registered handlers are available in `tay.tasks`, keyed by job name.  Calling
`await tay.enqueue("accounts.refresh.v1", {"account_id": "acct-42"})`
remains fully supported.

For payments and other external effects, pass the same stable business
operation identifier as Tay's `submission_id` and the provider's idempotency
key. A Tay retry can then repeat delivery without repeating the external
effect. See the repository's
[idempotency guide](https://github.com/AndriiSydorenko1904/tay/blob/v1.4.8/docs/idempotency.md)
for crash cases and a complete financial-operation example.

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
automatic discovery. In Docker, mount the same socket volume into Tay at
`/run/tay` and the worker at `/run/tay:ro`; no `TAY_SOCKET_PATH` is needed.
The mount is required even with `network_mode: "service:tay"`, which shares
networking but not the filesystem. The shared directory selects
`/run/tay/tay.sock` even before the listener creates it, so worker startup and
reconnects do not depend on scanning for socket files. Both containers need
compatible socket ownership/group permissions. See the repository README for the current durable-result/
scheduling compatibility boundary.

## License

The `tay-client` Python package is licensed under the MIT License. The Tay
engine is distributed separately under the Elastic License 2.0.


## Bounded result waiting

```python
job = await producer.enqueue("billing.capture.v1", {"invoice_id": "inv-42"})
value = await job.wait_result(timeout=30, poll_interval=0.1)
```

Both HTTP and socket handles use the same wait contract. The deadline includes
network requests and polling. `None` is a successful stored JSON null;
`ResultMissing`, `JobCancelled`, and `RemoteTaskError` are terminal. A timeout
raises `TimeoutError`; cancelling the awaiting coroutine cancels only the wait.
Neither operation cancels or resubmits the job. Connection/unavailability errors
propagate so callers can make an explicit retry decision.

Submission options follow the complete Protocol v1 contract. `priority` is not
supported. `delay`/`timeout` are seconds, `delay_ms`/`timeout_ms` are milliseconds,
`run_at` is an absolute Unix millisecond timestamp, and conflicting aliases are
rejected locally. Server-side admission, clock and storage limits still apply.

## Worker CLI and diagnostics

```sh
tay worker app.jobs:worker
# Backwards-compatible spelling:
tay-worker app.jobs:worker
python -m tay worker app.jobs:worker

tay doctor --json
tay doctor --socket-path /run/tay/tay.sock
tay doctor --http-url http://127.0.0.1:8080 --timeout 5 --json
```

`worker` may be `Tay(mode="worker")` or `TayHTTPWorker`. Module-only discovery
requires exactly one exported worker instance. SIGINT/SIGTERM also interrupt
startup and registration retries; execution/transport cleanup is awaited.

Doctor does not submit jobs, register workers, change permissions or create
storage. Socket output includes the exact discovery origin, UID/GID, socket
ownership and access checks; the connectivity probe sends no protocol frames.
HTTP uses only `GET /health`. Exit status is zero on success, one for a failed
check, and two for invalid CLI/configuration. Credentials and passwords are
never printed. Remote HTTP requires HTTPS and mTLS; pass `--tls-ca-file`,
`--tls-cert-file`, `--tls-key-file`, or `--tls-pkcs12-file` with optional
`TAY_TLS_PKCS12_PASSWORD` in the environment.

A lost HTTP session retires old async tasks and waits for old synchronous calls
before registering again. A synchronous Python thread cannot be forcibly
stopped; a blocked call continues to occupy its slot. Late outcomes never use
a replacement token or socket connection, and no execution outcome is replayed.

## Durable schedules over either transport

`tay-client` 1.4.2 provides the same schedule API on `Tay` and `TayHTTP`:

```python
async with TayHTTP("http://127.0.0.1:4080") as tay:
    schedule = await tay.every(
        "reports.build.v1",
        minutes=5,
        declaration_id="reports-five-minutes",
        overlap="queue",
        catch_up="all",
    )
    print(await schedule.status())
    print(await tay.schedules())
    print(await tay.get_schedule(schedule.id))
    await schedule.cancel()
```

`allow` admits independent occurrences. The default `skip` advances past due
times while the preceding job is nonterminal. `queue` holds the due occurrence
until that job finishes; `all` catches up serially and `latest` coalesces later
missed times after delivery. Schedule state survives restart and compaction.
Use a stable `declaration_id` to reconcile a lost registration reply. Cancellation
withdraws a declaration before sending the request, so automatic reconnect does
not resurrect it after an unknown outcome. Explicit registration can enable it
again. HTTP worker decorators accept `cron`, `every`, `overlap` and
`declaration_id`, using the same validation as Unix workers.

Schedule listing keeps the `await client.schedules()` list API and automatically
follows bounded server pages for both HTTP and Unix transports. All retained Tay
data shares the server's `max_state_bytes`; admission may return `capacity` when
the common budget is full. No schedule/result memory split is required.
