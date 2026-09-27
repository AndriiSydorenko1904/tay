# Executor Protocol v1 and HTTP/JSON producer API

Tay's language-neutral executor boundary is a Unix-domain socket (UDS) on the
same host. Socket and directory permissions define who may submit, inspect,
cancel, and execute work. The socket is ephemeral and must stay outside the
durable `data_dir`. Set `executor_socket: nil` to disable it.

An optional Bandit HTTP/JSON listener exposes producer operations directly from
the Engine. It is disabled by default. Set `http_port` (or `TAY_HTTP_PORT` in
standalone) to enable it. Plain HTTP is limited to loopback; a non-loopback bind
requires mTLS. Workers still use Protocol v1 through the Unix socket.
HTTP clients need only an HTTP(S) URL; they never open the Unix socket. Tay's
server keeps the socket because external workers currently register and receive
jobs there. `http_port` with `executor_socket: nil` is therefore rejected.

## Socket discovery

The Engine and SDKs resolve the same path in this order: explicit application or
SDK path, `TAY_SOCKET_PATH`, a usable `XDG_RUNTIME_DIR/tay/tay.sock`, a usable
`TMPDIR/tay-<uid>/tay.sock`, then `/tmp/tay-<uid>/tay.sock`. Automatic final
directories are private (`0700`) and the socket defaults to `0600`; an explicit
socket mode may be `0600` or `0660`. Tay removes only a verified stale socket at
the resolved path and refuses to replace a regular file. Explicit paths require
an existing, suitably owned parent directory. A restart recreates the socket.

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
one-time delay/run-at, retries, timeout, queue, and Event-v1 exponential backoff.
`submission_id` deterministically derives the durable job ID. If a reply is
lost after enqueue, the result is unknown: retry only with the same ID and
definition, never with a fresh submission ID.

Completion state is durable; a successful return value is retained only in the
bounded current listener generation (`executor_result_bytes` and
`executor_max_results`). After restart, `result` may be JSON `null` for a
completed job. Protocol v1 is not a durable result backend. Cron and interval
schedules can be created and cancelled through `schedule` and
`cancel_schedule`; their registry belongs to the live listener generation.
The Python client retains successful declarations and replays them on listener
reconnect. Due occurrences retry temporary admission failure with a stable job
ID. A client-process restart still requires declaration at application startup;
missed-time catch-up and overlap enforcement are not yet available. Custom
retry curves, multi-host leases, and exactly-once external effects are
unsupported.

## HTTP/JSON producer API

The Bandit listener offers `POST /jobs` (enqueue), `GET /jobs/:id` (status),
`DELETE /jobs/:id` (cancel), and `GET /jobs/:id/result` (result). Enqueue accepts
`{"task":"billing.capture.v1","args":{},"options":{}}` with
`Content-Type: application/json`. Successful responses are JSON objects with
the equivalent Protocol v1 fields and `type`; enqueue returns HTTP 201.
Failures return `{"error":{"code":"..."}}` and an appropriate HTTP status.
The request and response body limit defaults to 1 MiB.
Plaintext loopback does not use socket file permissions: other processes on the
same host that can reach the port may use the producer API. Use mTLS or host
isolation when that trust boundary is too broad.

For remote access, configure `http_ip`, `http_port`, and all three
`http_tls_certfile`, `http_tls_keyfile`, `http_tls_cacertfile` options (or their
`TAY_HTTP_*` standalone equivalents). The CA authenticates client certificates;
all trusted clients currently have the same producer privileges. Restrict
network access and protect private keys. There is no per-client authorization
or certificate revocation checking.
