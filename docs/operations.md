# Tay operations

This is the Tay v0.5.0 public-preview operational procedure. R5 approves only
the finite measured reference profile and target-validation condition in
[production limits](production-limits.md), not this procedure alone or an
unrestricted production deployment. Package publication remains a separate
action. No repair, compaction, live backup or distributed execution is provided.

## Deployment boundary

Run one Engine against a whole store on explicitly validated local Linux storage
with `durability: :sync` and `validated_filesystem: true`. The flag is an operator
attestation, not filesystem/device certification. Verify file and directory sync,
advisory locks, exclusive publication, stable identities, mount configuration and
the device's documented power-loss behavior. See the frozen Phase 2 platform assumptions and
the actual tested matrix in the implementation report. NFS/SMB, network/object
stores, Windows and macOS production durability are unsupported. Explicit macOS
development `:write` has no power-loss durability promise. Never silently fall
back from sync to write. A built production application rejects write mode.

Provide an absolute, dedicated local path in the consuming application's runtime
configuration; dependencies do not import this repository's Mix config:

```elixir
config :tay, data_dir: "/srv/tay/jobs"
```

Initialize once as an administrative operation, then supervise the Engine:

```elixir
Tay.child_spec(
  name: MyApp.Jobs,
  data_dir: "/srv/tay/jobs",
  durability: :sync,
  validated_filesystem: true,
  workers: %{"mail.send.v1" => MyApp.MailWorker},
  queues: [default: 2],
  start_paused: true
)
```

The example is schematic, **not** the jointly measured R5 workload or its finite
admission configuration. Apply every R5 boundary from
[production limits](production-limits.md), then validate the actual target and
workload before deployment. Startup is
existing-only: a missing root, lock, STORE or required canonical is an error,
never permission to initialize. `Tay.Storage.initialize/1` and
`mix tay.storage.init` are initialize-only, not idempotent ensure operations.
Only an explicitly intended empty pre-existing root permits `bootstrap: true`
(CLI `--bootstrap-existing`). Never delete/recreate a lock to resolve contention.
See [packaging](packaging.md) for the build-only C11 dependency and consuming-release
verification. Running a built release must not build a native helper.

## Queue controls and drain

All calls select the Engine with `name: MyApp.Jobs`; default name is `Tay.Engine`.
Finite `timeout` is a caller deadline in milliseconds, not a worker timeout.
Queue controls accept a configured trusted queue atom or its stable UTF-8 key.

```elixir
:ok = Tay.pause_queue(:default, name: MyApp.Jobs)
:ok = Tay.resume_queue(:default, name: MyApp.Jobs)
:ok = Tay.drain(name: MyApp.Jobs, timeout: 30_000)
```

Pause serializes through the sole semantic Engine owner. After its accepted
barrier there are no new claims for that queue; already durably started tasks
may enter/continue and produce external effects. A pause reply is not proof that
all workers are dead. Pause is volatile, creates no Event and resets to the
boolean `start_paused` configuration on every fresh generation. `true` pauses all
configured queues initially; `false` pauses none.

Drain closes new-insert and new-claim admission, stops automatic due-event
production, and allows active settlements. It succeeds only when all registered
execution tasks are dead and their accepted outcomes are durably committed and
projected. Queued, scheduled and retryable jobs may remain. Same-ID/same-definition
insertion reconciliation and lookups remain available; new IDs are refused with
`:draining`. Explicit revision-checked cancellation/manual retry still serialize
normally, but do not restart dispatch. Queue resume does not undo Engine drain.

A drain timeout leaves `:draining`; it never resumes or force-kills work. If a
submitted call loses its reply, its barrier may still have taken effect:
`:unknown_outcome` is not proof of no change. Bounded status/explicit new control
calls reconcile operational intent; no pending RPC is automatically retried.
Concurrent drain waiters occupy the existing fixed client permits and expire;
execution outcome capacity is separate and remains usable under client saturation.

## Explicit stop/restart

```elixir
:ok = Tay.stop(name: MyApp.Jobs, timeout: 30_000)
:ok = Tay.restart(name: MyApp.Jobs, timeout: 30_000)
# Explicit infrastructure interruption, not successful drain:
Tay.stop(name: MyApp.Jobs, force: true, timeout: 5_000)
```

Stop retains the original host-supervised root and bounded named lifecycle
coordinator in `:stopped`; it does not move ownership under the caller. Remove the
host child through its own supervisor if that coordinator should also disappear.
Restart uses the retained validated startup configuration and a new generation.
A separate single control permit serializes stop/restart independently of client
slots. Once closing/recovery begins, caller timeout reports unknown outcome and
that permit remains occupied until the real operation resolves; it never spawns
a second replacement. Status can remain `:stopping`/`:recovering` while proof is
pending. After graceful timeout, the Engine remains draining/drained, not resumed.

Once lifecycle drain acknowledges quiescence to its coordinator, queued
cancel/retry commands cannot begin another append before closing. They receive
known pre-I/O `:generation_stopping` when processed, or a conservative unknown
outcome if the submitted caller loses its generation. This extra barrier belongs
to stop/restart; plain drain continues to permit explicit administration. An
expired/aborted lifecycle token does not permanently block drained-state admin.

Normal stop first drains. Forced stop is a distinct explicit operation, not a
successful drain or an assertion that external effects did not occur. The old
generation's admission is revoked before its runtime group is dismantled. Local
task death is proven separately from OS lock release: a released flock or exited
supervisor alone does not authorize replacement callbacks. A poisoned Writer,
lost helper, Engine, execution runtime or local fence revokes the whole generation.

Restart performs full existing-only physical/semantic recovery and revalidation,
then creates new private ETS and execution state. It never inherits a writable
reference, projection or pending RPC. Every complete understood event replays,
even if its previous caller ACK is unknown. An execution left in history is
settled as infrastructure interruption before dispatch readiness; its logical
attempt is reused with a fresh physical execution token. Completed work is not
silently undone. Changes to worker mappings/concurrency/configuration require a
controlled host-supervisor replacement with explicit new startup options, not
persisted configuration mutation or hot reload.

Normal stop does not seal the active segment. Native closure may finish after an
abrupt owner death, and a fresh attempt can report `ownership_busy`. There is no
automatic mutation retry or lock replacement. Loss of the VM-local fence ledger
while a lease exists deliberately requires a fresh VM for that STORE_ID: no API
erases an orphan marker or pretends missing task evidence is safe.

## Outcomes, cancellation and retry

Workers must make external side effects idempotent or reconcile them explicitly.
Tay provides at-least-once execution, not exactly-once external effects. Ordinary
worker failure/timeout consumes the logical attempt; infrastructure interruption
does not. Retry v1 uses the immutable Event appendix's bounded delay/jitter math.
Timeout is monotonic from post-commit release; schedule eligibility rechecks wall
time. Clock jumps do not justify early callback entry.

`Tay.cancel/2` durably fences an executing token before best-effort termination.
Late results cannot reverse cancellation; external effects already performed
cannot be reversed. `Tay.retry/2` expedites retryable work or begins a new cycle
for discarded work, retaining the immutable definition. Both use a captured
opaque job revision, never refresh it automatically, and return unknown outcome
with that exact context if a submitted request loses its reply. Reconcile before
deciding a new command. Cross-generation revisions intentionally conflict.

## Capacity and diagnosis

`Tay.status/1` is a bounded, stale-capable lifecycle snapshot, not a transaction,
backup or recovery certificate. It reports state, durability, charged candidate
bytes/nodes, retained jobs/definition bytes, canonical history bytes/segments,
remaining sequence/segment coordinates, active/paused queue credits, fixed client
permits and active outcome reserves. It exposes no job args, ETS identifiers,
Port or mutation reference. Charged bytes are not an RSS guarantee.

`max_history_bytes` and `max_segments` are non-persisted admission ceilings,
independent of physical validity and recovery budgets; defaults are `:infinity`,
not a production unlimited-history claim. Configure finite measured limits.
Every active outcome reserves 1,024 frame bytes plus a possible 64-byte footer
and 44-byte successor header, as well as one sequence/segment coordinate.
Inserts, starts and other producers cannot consume this reserved capacity.
Conservative reservation may refuse a start even when its particular outcome
would fit without rotating. Counters are initialized during recovery and updated
from verified receipts, not by scanning historical files for each insert.

No completed job/ID is evicted. Lower insertion limits do not invalidate retained
definitions or prevent same-definition reconciliation, subject to independent
transport/replay budgets. A lower operational budget can prevent reconstruction
or reconciliation; increase resources through an explicit configuration change
and fresh recovery, never delete history. Outcome reserves cannot protect against
actual ENOSPC, hardware failure or unlimited repeated crashes. Reserve free disk
outside these counters for stages, temporary copies, logs and filesystem overhead.

Offline `mix tay.storage.inspect` / `Tay.Diagnostics.inspect/1` acquire the existing
lock and run full physical/semantic validation without activation or successor
creation. They report ownership busy against a live Engine. Missing lock is an
ownership failure, not permission to create one. Diagnostics do not return jobs,
payloads or a reusable recovery ticket. See the task help for exact budget options.

## Fail-closed incident procedure

1. Stop external admission; record the bounded diagnosis and deployment/build ID.
2. Preserve the complete original store and namespace. Do not truncate, pad,
   delete, rename-aside, skip records, reuse sequence space or select a valid prefix.
3. Distinguish ownership contention, operational resource limits, unsupported
   semantics and physical corruption. Correct only operational configuration or
   ownership through documented procedures; no automatic repair is bundled.
4. If history is fully valid, restart with adequate budgets and supported code.
   If torn/corrupt/unsupported, writable activation remains refused.
5. If choosing an older acceptable backup, follow the separately qualified
   [cold restore procedure](restore.md), retain the failed source, and explicitly
   account for lost later ACKs and potentially repeated external effects.

A torn Record/footer/canonical suffix preserves all evidence and refuses writable
activation; it does **not** automatically recover a writable prefix. No partial
recovered job state is published. Without a valid acceptable backup, this can be
an operational outage with no supported in-place repair.

## Security and shutdown boundaries

The embedding application, configured modules and cooperative API callers are
trusted. Same-VM ETS/message/process access is not a hostile-code sandbox.
Persisted worker/queue keys remain inert UTF-8, never atom/module creation inputs.
Default diagnostics are fixed bounded codes, not worker exception/result dumps;
do not add application logs that reveal args or secrets. Payloads are plaintext
on disk; provision private ownership/permissions, encryption and backup access
controls externally.

Unlinked children created by a callback and remote side effects are outside Tay's
local task ledger. A worker stuck in a non-preemptible native call may prevent
proven local death and thus safe replacement; timeout is not a sandbox. VM/process
kill tests and a filesystem-type check do not certify real hardware power loss.

Phase 11 snapshots/retention/compaction and Phase 12 orchestration/uniqueness remain
deferred. Neither is a hidden remedy for this release's retained-history limits.
