# Operations

Run one Engine per whole store. Production `:sync` requires an explicitly
validated local Linux filesystem with truthful file and directory sync,
advisory locking, and exclusive rename semantics. `validated_filesystem: true`
is the operator's attestation, not a filesystem probe or device certification.
Never silently downgrade to `:write`; production builds reject that mode.
macOS `:write` is for development and carries no power-loss promise. A release
must be built for its target OS/architecture with Elixir 1.20, OTP 29, and a
C11 compiler at build time; the deployed release runs its included native
helper without Mix or a compiler.

## Initialize and inspect

Set a dedicated absolute `data_dir` in the consuming application's runtime
configuration, then initialize a genuinely new store once before supervising
the Engine:

```sh
MIX_ENV=prod mix tay.storage.init --data-dir /srv/tay/jobs --durability sync --validated-filesystem
MIX_ENV=prod mix tay.storage.inspect --data-dir /srv/tay/jobs --durability sync --validated-filesystem
```

Initialization is not an idempotent “ensure” or repair command. Normal startup
is existing-only; a missing lock, STORE marker, or required history is an error.
Only an explicitly intended empty pre-existing root permits
`--bootstrap-existing`. Never delete or replace a lock to bypass contention.
Offline inspection acquires the existing lock and performs complete physical
and Event-v1 semantic validation without activation. It returns aggregate
diagnostics, not jobs or a reusable recovery ticket. Use `mix help
tay.storage.inspect` for independent replay budgets.

Explicit initialization is the default operational model (`initialize: :never`).
Embedding applications that need first-start creation, such as containerized
deployments, may opt into `initialize: :if_missing` on `Tay.child_spec/1`. The
native ownership layer initializes only when it creates the final storage root;
every pre-existing root remains existing-only and proceeds through normal full
recovery. This option is initialization only, never repair or a fallback after
recovery failure.

## Local executor access

An Engine normally creates its Unix socket automatically outside `data_dir`.
The final automatic directory is private (`0700`), and the socket defaults to
`0600`. An explicit path or `TAY_SOCKET_PATH` overrides discovery; prepare the
parent ownership and permissions yourself. Tay refuses a regular file at the
socket path and removes only a verified stale socket. Grant access only to
trusted local processes: a peer can submit, inspect, cancel, and execute tasks.
Bound connection, frame, task, result, and error limits for the workload. See
the [protocol contract](protocol.md) for the wire format and result lifetime.

## Queue and lifecycle controls

Use `name:` when an Engine has a nondefault name. Pause is volatile and stops
new claims, not already-started effects. Drain closes new insertion/claim
admission and succeeds after active tasks and their outcomes settle; queued
jobs may remain. A timeout leaves the Engine draining. Stop normally drains;
forced stop is an explicit interruption, not successful drain. Restart creates
a fresh ownership, recovery, projection, and execution generation:

```elixir
:ok = Tay.pause_queue(:default)
:ok = Tay.resume_queue(:default)
:ok = Tay.drain(timeout: 30_000)
:ok = Tay.stop(timeout: 30_000)
:ok = Tay.restart(timeout: 30_000)
```

An unknown outcome after a submitted insert or control call does not prove no
change. Reconcile by stable job ID, original definition, status, or a new
explicit control decision; do not automatically allocate another job ID.
Worker effects are at-least-once. Cancellation fences the durable execution
token before best-effort termination but cannot undo an effect already made.

## Live inspection and dashboard

`Tay.jobs/1` returns public `Tay.Job` views in deterministic newest-first
insertion order. It accepts state, queue, exact worker-key (`worker`/`workers`),
partial worker-key (`worker_contains`), ID, limit, and opaque cursor filters.
Pages are capped at 100 results. Each response includes the exact matching
`total_count` plus opaque `previous_cursor`, `next_cursor`, and `last_cursor`
values for bidirectional and final-page navigation. The first page uses no
cursor. Cursors are tied to their filters. Concurrent inserts and state changes
produce a weakly consistent live view, so refresh after administrative actions
or engine restart.

`Tay.stats/1` and `Tay.queues/1` use reconstructable runtime counters rather
than scanning retained history. The optional `tay_dashboard` Hex package mounts
these APIs in a host Phoenix application. It is not an authentication boundary;
protect its router scope with the host application's administrator pipeline.

## Store-v2 automatic compaction

The per-Engine policy is enabled when `compaction:` is omitted. It uses finite
terminal retention and conservative sealed-history estimates, not periodic full
replay. Compaction closes admission, settles execution and uses the sole Writer's
qualified candidate / validation / CURRENT / deferred-reclamation path.
It does not run online. All thresholds are conjunctive; a timer alone never
authorizes a rewrite. Cooldown uses the later of the verified manifest capture
time and post-publication recovered activation time. Restart conservatively
extends cooldown rather than shortening it by construction time. Backward clocks
conservatively defer.

Configuration (milliseconds except the explicit retention unit):

```elixir
compaction: [
  enabled: true,
  terminal_retention: {:hours, 24},
  check_interval: 60_000,
  min_interval: 3_600_000,
  min_sealed_segments: 1,
  min_reclaimable_bytes: 16_777_216,
  dead_ratio_threshold: 0.25
]
```

Unknown/duplicate keys, unbounded/nonpositive timers or byte/count limits and
invalid ratios fail configuration. Timers/counts fit unsigned 32 bits; bytes fit
signed durable time/integer range. Bounded hours use the shared manifest rule
`1..2_562_047_788_015`, not a separate configuration duration syntax. Ratios are
positive finite numbers at most one. Automatic configuration rejects infinity.

Retention is eligibility, not an exact-time deletion guarantee: terminal jobs
expire at `terminal_at <= captured_at - duration`, but actual work waits for
sealed-history thresholds, cooldown, healthy ownership, successful execution
drain and sufficient additional disk. The estimator retains at most 128 oldest
hour buckets, conservatively counting only fully expired hours (up to one extra
hour of estimation delay). Small/idle stores may retain terminals indefinitely
below thresholds. Live, scheduled, available, executing, retryable and unsettled
jobs are protected. Expired IDs are not remembered: get/retry/cancel return
not-found, and a later submission with that ID is a new job.

`compaction: false` disables the policy child/timer; reclaimable history may then
grow indefinitely and the operator assumes storage management. Manual work
remains available:

```elixir
{:ok, stats} = Tay.compact(timeout: 900_000)
{:ok, stats} = Tay.compact(terminal_retention: {:hours, 48})
{:ok, stats} = Tay.compact(terminal_retention: :infinity)
```

Manual/automatic/stop/restart share one fixed operation slot; a concurrent
administrative operation returns capacity/busy rather than queuing or forcing a
switch. Supervisor shutdown cancels the evaluator's timer and asks the owner
to cancel construction before CURRENT. Once CURRENT is in flight, it waits for
verification/reconciliation before retiring Engine and defers reclamation.
No source bytes are deleted to obtain candidate headroom. Payload-free aggregate
events are structured Logger debug metadata under `:tay_compaction`; enable
debug logging to observe evaluation/gate/defer/start/completion/failure events.
The qualification suite covers finite workload measurements and the documented
operational limits.

## Cold backup and restore

Stop and fence every Engine using the source before copying. The native tools
hold its **existing** exclusive lock throughout inventory, hashing, and copy;
they refuse a live owner. A cold copy is whole-store bytes, not a live snapshot,
semantic validation, repair, or a proof that the backup contains the latest
acknowledged history. Keep the SHA-256 catalog outside both stores. The source,
destination parent, and catalog parent must exist; destination and output
catalog must not. Do not run source and restored copies concurrently: they
share a STORE_ID.

```sh
MIX_ENV=prod mix tay.storage.backup \
  --source /srv/tay/jobs \
  --destination /srv/backups/tay-2026-09-13 \
  --catalog /srv/backups/tay-2026-09-13.json \
  --durability sync --validated-filesystem

MIX_ENV=prod mix tay.storage.restore \
  --source /srv/backups/tay-2026-09-13 \
  --destination /srv/tay/restored \
  --verify-catalog /srv/backups/tay-2026-09-13.json \
  --catalog /srv/backups/tay-restored.json \
  --durability sync --validated-filesystem

MIX_ENV=prod mix tay.storage.inspect \
  --data-dir /srv/tay/restored --durability sync --validated-filesystem
```

For development copies use `--durability development` on backup/restore and
`--durability write` on inspection. Strict copying is Linux-only on a supported
validated persistent local filesystem. The tools reject symlinks, hard-linked
source files, unsafe aliases, unexpected file types, changed ancestors/source
identities, missing/extra archive files, malformed catalogs, checksum mismatch,
and exhausted file/byte budgets. Defaults are 100,000 inventory entries
(including `segments`) and 10 GiB of file bytes; override only for a separately
qualified workload.

The destination is a new private `0700` sibling staging directory with `0600`
files. STORE is copied last. In strict mode every copied file is fsynced,
followed by the segments and store directories, exclusive no-replace
publication, ancestor syncs, then exclusive external catalog creation and its
syncs. A failure preserves the source and any partial staging or published
destination. A complete-looking destination without a successful catalog is
not acknowledged backup success; never overwrite it or infer a recoverable
prefix. Restore always verifies the selected backup's catalog before creating
destination data. An older valid backup explicitly accepts lost later jobs and
possible repeated external effects. Inspect and activate it in a fresh Engine
generation before admitting work.

## Incident boundary

On corruption, incomplete history, unsupported semantics, or an uncertain
storage operation, stop admission and preserve the entire store and namespace.
Do not truncate, pad, delete, rename-aside, skip records, or reuse sequence
space. Distinguish ownership contention and operational budget refusal from
bad bytes. Increase a budget only for a new full inspection of unchanged data.
There is no automatic repair, retention/compaction, or live backup. Protect
plaintext args, stores, catalogs, and backups with deployment access controls.
