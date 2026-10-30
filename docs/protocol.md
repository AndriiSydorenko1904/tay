# Executor Protocol v1 and HTTP/JSON API

Tay's language-neutral executor boundary is a Unix-domain socket (UDS) on the
same host. Socket and directory permissions define who may submit, inspect,
cancel, and execute work. The socket is ephemeral and must stay outside the
durable `data_dir`. Set `executor_socket: nil` to disable it.

An optional Bandit HTTP/JSON listener exposes producer and worker operations from
the Engine. It is disabled by default. Set `http_port` (or `TAY_HTTP_PORT` in
standalone) to enable it. Plain HTTP is limited to loopback; a non-loopback bind
requires mTLS. Enabling HTTP disables the implicit Unix socket in both embedded
and standalone mode. Set an explicit `executor_socket` path (or
`TAY_SOCKET_PATH`) to enable both transports. An explicit `executor_socket: nil`
or `TAY_SOCKET_PATH=off` disables the socket.

## Socket discovery

The Engine and SDKs resolve the same path in this order: explicit application or
SDK path, `TAY_SOCKET_PATH`, `/run/tay/tay.sock` when `/run/tay` exists, a usable
`XDG_RUNTIME_DIR/tay/tay.sock`, a usable `TMPDIR/tay-<uid>/tay.sock`, then a usable
`/tmp/tay-<uid>/tay.sock`. The same JSON fixtures test this contract in Elixir
and Python.

Automatic final directories other than the shared `/run/tay` are private
(`0700`), and the socket defaults to `0600`; an explicit socket mode may be
`0600` or `0660`. Tay preserves the ownership and permissions of the shared
`/run/tay` directory; containers must share it through a volume. Directory
existence selects the shared path even before the socket is created. An access
failure reports that path and its OS error rather than silently switching to
another socket. Workers may mount the shared volume read-only; their UID/GID
must still permit directory traversal and socket access.

Tay removes only a verified stale socket at the resolved path and refuses to
replace a regular file. Explicit paths require a suitably owned parent
directory. A restart recreates the socket.

## Wire format

Each message has a four-byte unsigned big-endian payload length followed by a
nonempty UTF-8 JSON object. `executor_max_frame_bytes` is checked before JSON
decoding. Values are bounded JSON null, booleans, finite numbers, strings,
arrays, and string-keyed objects; ETF, pickle, code loading, and shell execution
are not part of the protocol. Every envelope carries `version: 1`, a known
`type`, and a nonempty UTF-8 `request_id` of at most 128 bytes. Malformed or
oversized frames close only that connection. Correlated request failures use:

```json
{"version":1,"type":"error","request_id":"request-1","error":{"code":"..."}}
```

Error objects may include backward-compatible diagnostic fields. In
particular, an enqueue admission refusal uses `code: "capacity"` and includes
the bounded capacity category in `reason`, such as `"client_slots"` or
`"client_bytes"`.

The first request must be `hello` with `mode: "client"`, `"embedded"`, or
`"worker"`, a `runtime_id`, and `max_concurrency`. Clients declare zero
concurrency; executors declare `1..65535`. A successful handshake returns
`hello_ok`. Executors then register stable task keys with `register_tasks` and
may withdraw them with `unregister_tasks`:

```json
{"version":1,"type":"hello","request_id":"hello-1","mode":"worker","runtime_id":"worker-1","max_concurrency":4}
```

```json
{"version":1,"type":"register_tasks","request_id":"tasks-1","tasks":["billing.capture.v1"]}
```

Registrations, capacity, reservations, and successful return values belong to
the current live connection or listener generation. They are not persisted.
Disconnect immediately removes the runtime's capacity. Jobs without a capable
executor remain ready without consuming an attempt, and later compatible work
in the same queue may still run.

## Dispatch and producer requests

After a durable START, Tay sends `execute` with a job ID, task key, JSON args,
timeout, reservation ID, and execution ID. The executor acknowledges `started`
and reports `succeeded` with bounded JSON `result`, or `failed` with a bounded
error object. Reports must repeat both IDs; stale or mismatched completion is
rejected. `cancel_execution` is best effort. A disconnected in-flight task is
recovered as an infrastructure interruption and may run again; application
effects require idempotency or reconciliation.

```json
{"version":1,"type":"execute","request_id":"execution-1","reservation_id":"reservation-1","execution_id":"execution-1","job_id":"0123456789abcdef0123456789abcdef","task":"billing.capture.v1","args":{"invoice_id":"inv-42"},"timeout_ms":30000}
```

Producer RPCs are `enqueue`, `status`, `result`, and `cancel`. Enqueue accepts a
stable task key, a JSON-object `args`, and options for `id` or `submission_id`,
one-time delay/run-at, retries, timeout, queue, durability (`persistent` or
`volatile`), and Event-v1 exponential backoff.
`submission_id` deterministically derives the stable job ID. If a reply is
lost after enqueue, the result is unknown: retry only with the same ID and
definition, never with a fresh submission ID.

A successful `result` always contains a `result` field; JSON `null` is a valid
stored value. `result_missing` means a completed job has no retained result
(for example, a trusted local worker whose return value was not stored).
`task_cancelled` and `task_failed` are terminal errors; `result_not_ready`
means the job is still pending. Core read failures return `unavailable`, never
an invented successful null. HTTP maps these to 410, 409, 409, 409 and 503,
respectively; `not_found` remains 404.

Job option names are `id`, `submission_id`, `delay`, `delay_ms`, `run_at`,
`retries`, `timeout`, `timeout_ms`, `backoff`, `queue`, and `durability`.
`priority` is unsupported. Delay/timeout use seconds, their `_ms` aliases use
integer milliseconds, and `run_at` is an absolute Unix millisecond timestamp.
Positive halfway milliseconds round away from zero; a rounded-zero timeout is
invalid. Timeout is at most 86,400,000 ms, retries are 0..65,534, and timestamps
fit Event-v2's nonnegative signed-64-bit range. Relative schedules are also
validated against the server clock when the job is constructed. Do not combine
`id`/`submission_id`, delay units, timeout units, or delay with `run_at`.
The shared catalog is `clients/python/tests/fixtures/job_options_v1.json`.

For persistent jobs, completion state and a size-bounded successful JSON return
value are durable. The value survives restart and is retained with its completed
job; compaction removes it when that job expires under terminal retention.
Volatile jobs and results remain in the current in-memory generation. Cron and interval
schedules created through `schedule` are also durable and can be cancelled
through `cancel_schedule`. Due occurrences retry temporary admission failure
with a stable job ID, and schedule advancement is recorded only after durable
job admission. Client redeclaration with the same stable declaration ID remains
idempotent. Registration and cancellation replies are sent only after the
schedule mutation is durably committed. A lost post-commit reply is reported as
`unknown_outcome` and is never retried automatically; reconcile it by reading
the durable schedule state or by explicitly repeating the same stable
declaration. The `allow`, `skip` (default) and `queue` overlap policies are enforced
against the preceding nonterminal occurrence and retained through compaction and
restart. `queue` retries the same due occurrence until admission is possible;
`catch_up=all` delivers missed occurrences serially, while `latest` coalesces
later missed times after delivery. `skip` advances without admitting a new job
while the previous job is busy. Custom retry curves, multi-host leases, and
exactly-once external effects are unsupported.

Schedule reads are `schedules` (reply `schedules` with a `schedules` array) and
`schedule_status` with `schedule_id` (reply `schedule_status` with a `schedule`
object). Each object includes definition fields, revision, next/last due times,
cancellation time and `active_job_id`; a missing schedule is `schedule_not_found`.

HTTP exposes `POST /schedules`, `GET /schedules`, `GET /schedules/:id`, and
`DELETE /schedules/:id`. Creation accepts the same fields as Protocol v1
`schedule`, excluding envelope fields. Both Python transports expose `schedule`,
`every`, `schedules`, `get_schedule`, and handle `status`/`cancel`. Missing schedules
map to HTTP 404, invalid declarations to 400, and unknown outcomes to 503.
List responses obey the normal response byte limit and fail without a partial
list when it is exceeded.

## HTTP/JSON producer API

The Bandit listener offers `POST /jobs` (enqueue), `GET /jobs/:id` (status),
`DELETE /jobs/:id` (cancel), and `GET /jobs/:id/result` (result). Enqueue accepts
`{"task":"billing.capture.v1","args":{},"options":{}}` with
`Content-Type: application/json`. Successful responses are JSON objects with
the equivalent Protocol v1 fields and `type`; enqueue returns HTTP 201.
Failures return `{"error":{"code":"..."}}` and an appropriate HTTP status.
The request and response body limit defaults to 1 MB.
The listener uses Bandit's current HTTP/1.1 and HTTP/2 defaults.
Plaintext loopback does not use socket file permissions: other processes on the
same host that can reach the port may use the producer API. Use mTLS or host
isolation when that trust boundary is too broad.

For remote access, configure `http_ip`, `http_port`, and all three
`http_tls_certfile`, `http_tls_keyfile`, `http_tls_cacertfile` options (or their
`TAY_HTTP_*` standalone equivalents). The CA authenticates client certificates;
all trusted clients currently have the same producer privileges. Restrict
network access and protect private keys. There is no per-client authorization
or certificate revocation checking.

## HTTP workers

Workers register with `POST /workers` and a JSON body containing `runtime_id`,
`tasks` (capability names), `capacity` (1–256), and optional `queue` (default `default`).
The response contains an opaque `worker_token`. Subsequent worker requests send
`Authorization: Bearer <worker_token>`. `POST /queues/:queue/claim` long-polls
for up to 20 seconds and returns an `execute` or `cancel_execution` JSON event,
or HTTP 204 when no event is ready. `POST /workers/started` acknowledges an
execution; `POST /workers/complete` reports `outcome: success` with `result`,
or `outcome: failure` with a bounded `error` object. Both include the received
`reservation_id` and `execution_id`. `DELETE /workers` closes a session.

The session expires after 60 seconds without a claim. Lost sessions release
capacity and reconcile in-flight work through Tay's existing at-least-once
recovery path. Workers must keep polling while tasks run. HTTP workers require
HTTPS with mTLS when Tay listens on a non-loopback address. The token is a
session credential; keep it secret and never log it.

### Bounded schedule reads

`GET /schedules` and the UDS `schedules` command return a bounded page with
`schedules` and nullable `next_cursor`. Optional `limit` is 1..100 (default 50);
pass the returned `cursor` to continue. Pages may be shorter to bound response
construction. Cursors are exclusive schedule IDs in lexical order, not snapshot
tokens; concurrent updates may appear on a subsequent read. A single declaration
still has to fit the configured response/frame limit. Python `schedules()` and
Elixir `Tay.schedules()` fetch pages automatically and retain their list interface;
use `Tay.schedule_page()` to consume individual pages. The Dashboard uses pages.
`GET /schedules/:id` / `schedule_status` use direct lookup.

Changing `allow` to `skip` or `queue` checks all active occurrences, including
older runs when the latest one already finished. Occurrence membership is
checkpointed. Legacy allow checkpoints without complete membership cannot safely
be tightened and return `schedule_conflict`; cancel that declaration and use a
new declaration ID for the stricter policy.
