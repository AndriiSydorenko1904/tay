# RFC: accelerated roadmap from v0.3.0 to the first production-usable Tay

Current release reconciliation (2026-09-13): Phases 4–6 and R1–R4 were
implemented; R5 is approved only for the finite Tay v0.5.0 public-preview
profile and target-validation condition in [production limits](production-limits.md).
The dated proposal/approval text below is retained as historical design input.

Status: **R1/R3/R4 architecturally APPROVED; R2 specified for approval; no implementation authorized.**
Date: 2026-09-12.
Inspected HEAD: `741d6cb724eab6daa8dc88f9c15a5eb0ca366bcb`, `main`, tag `v0.3.0`.
The worktree was clean before this document was created.

Approval reconciliation: the user's subsequent approval makes R1/R3/R4 and
their twelve stated decisions normative. Phases 4–6 replace the old granular
Phase 4–10 implementation sequence. Historical proposal/gate wording below does
not reopen those approvals. The [Event v1 normative appendix](event-v1-contract-appendix.md)
fills only R2 and the concrete constants required by R3; it awaits approval.
R5 remains a production-release gate, not Phase 4 implementation authorization.

## 1. Recommendation and release boundary

Use **three cohesive implementation phases**, numbered 4–6 in this proposed
accelerated roadmap:

| Phase | Deliverable | Original TAY_PLAN coverage | Release meaning |
| --- | --- | --- | --- |
| 4 — Durable job core | Production Event schema, shared transition model, private ETS generation, insertion/lookup/reconciliation and explicit engine lifecycle | Missing Event dependency + original 4–5 + foundation of 9 | Durable jobs can be stored and reconstructed; no execution yet |
| 5 — Complete execution lifecycle | Bounded multi-queue execution, durable starts/outcomes, retries, scheduling, cancellation and manual retry | Original 6–9 together | Functionally complete job engine; not yet production-qualified |
| 6 — Production qualification and operations | Operational controls, capacity envelope, deployment/restore drills, compatibility/security/fault matrix and release packaging | Original 10 + operational requirements throughout the plan | First production-usable release, only after measurable exit gates pass |

Design these together now. Implement them sequentially, stopping for review at
each phase exit. Within a phase use reviewable commits, not a single giant patch;
those commits are implementation slices, not more architectural phases.
Tests, fixtures and fault hooks arrive with the feature they protect, never at
the end as a substitute for earlier correctness review.

The first production target is deliberately narrow: one local store/engine,
single-node Elixir, multiple queues, bounded retained history and memory, strict
`:sync` on an explicitly validated supported Linux filesystem, idempotent worker
side effects, and operators who accept fail-closed availability on damaged or
torn canonical history. macOS remains a development `:write` target.

This is **not** a claim of unattended writable restart after every crash, unlimited
retention, high availability, exactly-once execution, or arbitrary workload scale.
No acknowledged job may be discarded to improve availability or meet a budget.
Capacity exhaustion pauses admission/execution safely; it does not delete jobs.
If production usability requires automatic torn-tail repair or unbounded growth,
that is a different critical path requiring separately reviewed repair or
snapshot/retention protocols. Do not silently weaken the first-release contract
to claim that target has been met.

## 2. Authority, inspected evidence and reconciliation

Read completely: [TAY_PLAN.md](../TAY_PLAN.md); the
[Phase 1 RFC](phase-1-storage-format-rfc.md),
[Phase 2 RFC](phase-2-segment-format-rotation-rfc.md),
[Phase 3 RFC](phase-3-recovery-rfc.md); their
[Phase 1](phase-1-implementation-report.md),
[Phase 2](phase-2-implementation-report.md) and
[Phase 3](phase-3-implementation-report.md) implementation reports;
[accepted adversarial input](phase-1-review-input.md),
[original storage candidates](storage-rfc-input.md),
[Phase 2 gate reconciliation](phase-2-implementation-decomposition.md), and
[current architecture](architecture.md).

Inspected current foundation modules, recovery and Writer control flow, Reader
and native boundaries, the existing test inventory and representative semantic,
ownership, lifecycle and public-foundation tests. Source/API references below
describe the tagged HEAD, not imagined future APIs.

The original plan remains authoritative until this regrouping is approved.
Approval should reconcile its Phase 4–10 roadmap and production-exit wording;
this document does not modify TAY_PLAN.md or historical RFCs. Original Phases
11–12 remain deferred. Old “proposed/no implementation authorized” statements in
the Phase 2/3 RFCs are historical: subsequent approvals, accepted implementations
and `v0.3.0` establish the current baseline. They do not reopen G1–G6.

| Current evidence | Consequence for the next phases |
| --- | --- |
| `Tay` has documentation, not `insert/get/cancel/retry` functions; `Tay.Worker` only has `perform/1` | Public convenience APIs and their error contracts genuinely remain to be built |
| `Tay.Job` is a runtime struct, with no stable persisted IDs, timestamps or argument encoding | Never serialize it; introduce an independent Event/domain representation |
| `Tay.Config` validates only path and queue configuration; application starts an empty supervisor | A production engine is a new explicit lifecycle, not a reinterpretation of today's successful application startup |
| `Recovery.EventDecoder` has capability and exact-consumption callbacks; implementations are test-only | Production Event schema/support is the first critical dependency, before projection/insertion |
| `Writer.start_recovered_link/2` returns an awaiting-activation owner; `activate_recovered/2` returns candidate and distinct admission reference | Engine must keep this same Writer alive and publish its own readiness only after activation and index construction |
| Reducer runs synchronously inside Writer and must remain pure | Building ETS inside the existing recovery callback, or calling back into Engine/Writer, is not an approved shortcut |
| Writer can remain alive in `:poisoned`; its child spec is temporary | Monitoring process death alone cannot revoke a live engine on idle helper failure; an additive poison notification is needed |
| Raw `Writer.start_link/1` can bootstrap and create a highest-sealed successor before semantic validation | It cannot be the ordinary engine startup or failed-recovery fallback |
| `Writer.verify_current/1` and successor verification inspect store history | Current rotation/sealing can cost O(history), not merely O(active segment); qualify this cost, do not advertise bounded rotation latency |
| CRC32C is a bit-by-bit reference implementation; Phase 3 reports a 450.4 s combined large-test run | Historical verification is not a throughput benchmark; performance claims require measurements on realistic Events |
| All 40 binary fixtures and existing failure classifications are pinned | New semantic fixtures complement them; never assign job meanings to old opaque fixture contents |
| `mix.exs` still declares `0.1.0-dev`, despite Git tag `v0.3.0` | Packaging/version alignment is a release task, not evidence that a published production package exists |

Further plan ambiguities resolved by this proposal:

- Original execution, completion and scheduling phases share one crash-sensitive
  attempt protocol. Combining them avoids a milestone that can start work but
  cannot durably settle or retry it.
- Original `job_failed` then `job_retry_scheduled` illustrations are not a
  requirement for two writes. One atomic outcome Event must include its final
  retry/discard decision and due time.
- The plan's `:none`/`:flush` examples do not override approved `:write`/`:sync`.
- “Torn-tail recovery” in the production checklist retains G1's preserve-and-stop
  meaning. Production availability must be stated separately.
- Scheduling/time, retry interruption accounting, executing cancellation,
  unknown-commit reconciliation, ETS publication and missing worker handling
  have no frozen production semantics yet; the recommendations below require
  explicit approval, not an implementer's inference.
- No full historical scan is added for selection or ordinary lookup. The existing
  storage rotation scan is a separate, disclosed limitation of the current code.

## 3. Frozen contracts and cross-phase invariants

No discovered issue in this inspection requires changing a frozen format.
The following remain binding for every proposed phase:

| ID | Invariant |
| --- | --- |
| F1 | Record v1: 24-byte header, 28-byte overhead, exact CRC32C/coverage/order, nonzero contiguous uint64 sequences, assignable physical types 1–254 and schemas 1–255, 16 MiB payload hard limit |
| F2 | STORE 28 bytes; segment header/footer 44/64 bytes; 20-digit names; 1 GiB sealed-segment bound; immutable store identity, anchors, reserved fields and active/sealed topology |
| F3 | Same Writer → native helper/Port → flock across existing-only inspection, full physical preflight, semantic replay, candidate, revalidation and activation; no offline activation ticket |
| F4 | No implicit creation in recovery, skipped semantics, partial recovered success, automatic repair, truncation, padding, deletion, rename-aside, sequence reuse or acknowledgement frontier |
| F5 | Every complete physically valid contiguous understood event replays, regardless of unknown prior ACK; physical success is neither semantic acceptance nor observed caller success |
| F6 | Native helper owns all writable storage FDs; existing file/directory barriers and no-replace publication precede required receipts; no uncertain mutation retry or durability downgrade |
| J1 | The log is truth; indexes, caches, timers, running-process maps and admission counters are disposable, generation-local state |
| J2 | One pure transition model drives live validation/application and replay; no worker, wall clock, randomness, ETS side effect or external I/O in replay |
| J3 | No user-visible success, runnable index publication or worker release before the corresponding complete durable event and coherent projection |
| J4 | No stale execution result, old engine request, late timer or stale revision can mutate a newer job/engine state |
| J5 | Bounded admission precedes payload-bearing mailbox messages; selection is indexed and bounded; results/control work cannot be starved by insert load |
| J6 | Persisted names/values are inert and independent of runtime structs, atoms and loaded modules; unsupported Event schemas stop recovery untouched |
| J7 | At-least-once means duplicate worker side effects remain possible; no API cancellation, process monitor, token or file lock promises external exactly-once behavior |

F1–F6 restate frozen contracts. J1–J7 are proposed integration obligations for
TAY_PLAN invariants A–J, not new interpretations of physical validity.
Unless explicitly marked development-only, “durable,” “sync” and success
guarantees below describe the production `:sync` path. Development `:write`
exercises the same sequencing against its weaker, explicitly labeled receipt;
it must never claim crash durability or pass production qualification as `:sync`.

## 4. Shared Event and job design — approval required before Phase 4 code

### 4.1 Recommended persisted value model

Recommend a small, explicitly specified **tagged binary Event value profile**,
not ETF and not serialized structs. It has no compression, extension objects,
references, executable terms, module names to resolve, or user-defined decoders.
Use a canonical, string-keyed map for each Event and strict required fields per
type/schema. Integers, lengths and float bits are big-endian.

Alternatives considered:

| Option | Benefit | Cost / disposition |
| --- | --- | --- |
| ETF, even restricted | Convenient runtime terms | Does not meet the intended runtime-independent default without a carefully restricted contract; not selected, remains unapproved |
| General JSON/MessagePack/CBOR implementation | Familiar data vocabulary and potential library reuse | Still needs exact numeric/canonical/duplicate-key/extension rules and incremental depth/node/expansion enforcement; no unreviewed library default |
| Small specified binary value profile | Fixed inert vocabulary, exact consumption, bounded pre-allocation checks, no runtime dependency | Tay owns a small long-lived codec and independent fixtures; recommended for the bounded initial schema |

Proposed value encoding, sufficient to identify the chosen representation rather
than leaving “custom binary” unspecified:

| Tag | Following bytes / rule |
| --- | --- |
| `00`, `01`, `02` | No body: nil, false, true respectively |
| `03` | Signed int64, strictly negative; nonnegative values in this tag are noncanonical |
| `04` | Unsigned uint64; all nonnegative integers use this tag |
| `05` | IEEE binary64 bits, finite only; preserve signed zero; integer and float representations remain distinct |
| `06` | uint32 byte length + exact valid UTF-8 bytes |
| `07` | uint32 byte length + opaque bytes, permitted only in explicitly binary schema fields such as job IDs |
| `08` | uint32 item count + that many values |
| `09` | uint32 entry count + pairs of UTF-8 text-key values and value values; keys strictly ascending by UTF-8 bytes, no duplicates |
| Other | Unsupported value tag; no skip/extension fallback |

An Event payload is exactly one map, with no trailing bytes. Field names are
case-sensitive and not Unicode-normalized. Missing or extra fields fail schema
validation; adding an incompatible field requires a new per-type schema ID.
Metadata unsigned counters have their additional field bounds checked. Args must
be a map of string keys and recursively nil/boolean/integer/finite-float/text/
list/map values; raw-byte tags, tuples, structs and runtime atoms are not args.
Bounds count container/scalar/key nodes, nesting and aggregate text/binary bytes
while decoding, before allocation/expansion. Container count is never an allocation
instruction before input/resource checks. Schema checks then restrict each field.

This is a **proposed new semantic payload contract inside unchanged opaque Record
payloads**, not an approved production allocation by the act of writing this RFC.
Before its implementation, review a conformance appendix containing literal
independently calculated complete Event frames, every exact schema field/domain
and negative vector, including floats/UTF-8/duplicate keys. That appendix belongs
to the Phase 4 design gate, not a fourth implementation phase. Do not start a
temporary serialization that will later need migration.
Old Phase 3 test-provider stores are not production job-schema fixtures and get
no implicit migration/fallback. Preserve their existing tests/providers intact;
production compatibility starts with the independently pinned Event fixtures.

### 4.2 IDs, identity, time and immutable definition

- Job ID: recommend 16 non-all-zero CSPRNG bytes, public lowercase 32-hex form.
  Do not derive it from the log sequence. The builder allocates it before an
  insert can be sent, so the caller can reconcile an unknown result. A collision
  must hit the same-ID validation path, never overwrite. Time-sortability is
  deliberately unnecessary: queue order has explicit keys. UUIDv7/ULID would
  add clock/encoding rules without being needed for this first workload.
- Worker identity: explicit stable UTF-8 key, mapped by trusted configuration
  to a module implementing `perform/1`; never call `String.to_atom`, module
  concatenation or dynamic module loading on persisted names. Renaming a module
  preserves the key-to-new-module mapping. Keys must not be silently reused for
  unrelated behavior. Changing code behind a key still needs deployment review.
  A worker using the convenience macro declares its key explicitly; a bare
  `perform/1` implementation supplies `worker_key` to the builder. Builders freeze
  key/queue/policy into the definition before submission, not from mutable defaults
  on an unknown-outcome retry. New insertion validates that its trusted registry
  maps that key to the supplied module; replay has no such module requirement.
- Queue identity: persisted UTF-8 key, derived from configured trusted queue
  atoms without creating atoms from disk. Removed queues retain jobs and are
  runtime-disabled, not absent history. Rendering may expose the stable key when
  a current runtime atom/module mapping is absent.
- Event times and due times: UTC milliseconds since Unix epoch, nonnegative
  signed-int64 domain. Input DateTimes must convert without overflow. The domain
  model stores integers; presentation conversion is not replay interpretation.
  Monotonic time is used only for runtime durations/deadlines. There is no global
  requirement that historical wall-clock timestamps strictly increase.
- Immutable insertion definition: worker key, queue key, args, original requested
  due time (nil means immediate), max attempts, timeout and versioned retry policy
  parameters. The insertion Event separately records actual insertion time and
  resolved eligibility time. Retain the immutable definition for same-ID comparison,
  even as current state/attempts change.
- Stored policy values are used for later execution; changing worker defaults
  affects new jobs, never silently changes historical job policy. Decoder budgets
  and insertion limits are separate from policy/schema domains.
- Job revision is internally the last applied event sequence for that job.
  Expose it as an opaque optimistic-concurrency token, not as a storage cursor.
  Scope the public token to STORE_ID, job ID and the current engine generation;
  an old generation's administrative token is rejected, not refreshed silently.
  After restart the caller must explicitly reconcile and decide any new command.
  Each physical start's sequence identifies its execution within STORE_ID;
  expose an opaque execution token to workers if needed. No new persisted
  sequence allocator, epoch file or acknowledgement metadata is introduced.

### 4.3 Proposed event vocabulary and state machine

Proposed numeric IDs below are **new allocations for review**, not meanings
assigned retroactively to opaque physical fixtures. All initially use payload
schema 1. Phase 4 implements the complete pure decoder/transition vocabulary;
only insertion is exposed as a live command there. Phase 5 activates the remaining
command producers, avoiding a model rewrite halfway through execution work.

Every Event has `job_id`, `at` and `expected_revision`; insertion expects absent
job/revision 0, all others require the precise previous job revision. Event
revision becomes its own validated Record sequence. Replay never deduplicates
duplicate insertion or outcome records; invalid history stops.

| Type | Event and additional semantic fields | Legal transition / atomic effect |
| --- | --- | --- |
| 1 | `job_inserted`: immutable definition, resolved `eligible_at` | Absent → `available` if immediate/due at insertion, otherwise `scheduled`; attempt 0, next attempt 1; cycle token is this record's sequence |
| 2 | `job_available`: due time being satisfied | `scheduled` or `retryable` → `available`; event time must be at/after stored due; preserves next attempt/cycle |
| 3 | `job_started`: cycle token, logical attempt | Eligible `available` → `executing`; must match stored next attempt; execution token derives from this start's Record sequence |
| 4 | `job_finished`: execution token, outcome, bounded diagnostic, disposition, next due/attempt where applicable | Matching `executing` → `completed`, `retryable`, or `discarded`; failure and its retry/discard decision are ONE event |
| 5 | `job_cancelled`: current execution token or nil | `available/scheduled/retryable/executing` → `cancelled`; fence future starts/outcomes; process termination is a later runtime effect |
| 6 | `job_retried`: `expedite` or `new_cycle`, new due time | `retryable` → `available` without resetting logical attempt; or `discarded` → `available`, new cycle token from this event, attempt 0 / next attempt 1 |

Fields which do not apply have explicit nil values in the final schema, not an
implicit optional-field convention. The Phase 4 conformance appendix must fix
the exact key sets and enum encodings; ordinary strings above name meanings,
not permission for arbitrary event maps or free-form state changes.

Additional binding recommendations:

1. `:ok` and `{:ok, result}` complete a job; arbitrary `result` is not persisted.
   Results are not a durable result-store feature. Errors/raises/throws/exits and
   timeouts become bounded explicit failure classes. Do not invoke arbitrary
   `Inspect` or exception callbacks to serialize a reason.
2. Failure at logical attempt N retries at N+1 if N < stored `max_attempts`,
   otherwise discards. Compute backoff/jitter once outside replay and persist
   the chosen absolute due time and disposition in `job_finished`. Use a fixed
   reviewed policy v1: capped exponential delay with bounded integer jitter,
   checked/saturating arithmetic before addition to the timestamp. Exact base,
   cap, jitter range and default timeout are Phase 4 schema/policy gate values.
3. An `executing` job after full replay is **still executing in reconstructed
   history**. Before dispatch, after Phase 3 activation, append a normal
   `job_finished(outcome: interrupted, disposition: retryable)` via the live
   command path. This is logical attempt recovery, not physical tail repair.
4. Recommend retrying an infrastructure-interrupted execution at the **same
   logical attempt ordinal**, with a fresh start/execution token. A crash after
   durable start but before callback entry must not exhaust the retry budget
   without ever running the job. Thus `max_attempts` bounds settled logical
   failure attempts, not all physical invocations; repeated infrastructure
   interruptions can exceed it in physical invocation count. This choice is an
   explicit approval gate. Observed worker failures/timeouts do consume attempts.
5. Manual retry of discarded work begins a new cycle with the original policy;
   lifetime execution tokens never reset. Retry of completed/cancelled work is
   rejected; explicitly insert a new job for that intent. Retry of available or
   executing work is also rejected, not an implicit second start.
6. Running cancellation is a durable fence plus best-effort task termination,
   not reversal of side effects. Persist cancellation first; then request task
   termination, keep the concurrency slot until monitored death, ignore late
   results for that execution. If completion is serialized first, cancellation
   reports terminal conflict. Cancel of already-cancelled state is a no-write
   idempotent result; completed/discarded are explicit conflicts.
7. The minimum job view retains only the latest bounded error diagnostic (the
   existing `errors` runtime list can contain zero/one item). Older diagnostics
   remain in the log. No unbounded per-job error/result accumulation or history
   query API is introduced. Diagnostic schema/cap must be fixed before encoding.

### 4.4 Same-ID insertion and unknown outcomes

For a new ID, validate the immutable definition and current admission limits,
then commit the insertion. For an existing ID with a byte-equivalent canonical
immutable definition, return the existing job without another append, including
when it is terminal. Compare the definition exactly, not only a hash and not
current state/timestamps. Different definition → `:id_conflict`, no write.
Check this reconciliation path before new-insertion limits: lowering those
limits must not prevent recognizing an already-accepted job.

Transport timeout, caller death, writer/engine exit after submission or lost
reply produces an **unknown outcome** with job ID and operation/revision context,
not “not inserted.” No SDK/internal automatic retry. The caller can use a fresh
ready generation's lookup or explicitly resubmit the same immutable ID/definition.
Lookup during recovery/failure is `:unavailable`, never false `:not_found`.
This provides same-ID insertion reconciliation while all jobs are retained;
it is not args-based uniqueness, exactly-once execution, or an unlimited future
deduplication-retention promise. Future compaction must preserve this contract
or version it explicitly.

Administrative writes accept an expected opaque job revision. The `/1` convenience
form may capture it once via lookup, but any unknown outcome returns that captured
context and must not be retried against a freshly read revision automatically.
Repeated manual retries are new business actions, not transparent RPC retries.

## 5. Shared ownership, projection and command architecture

```text
Host supervisor: explicitly starts Tay engine (application foundation stays storage-free)
  Engine.Supervisor / lifecycle guardian
    ├─ admission gate + generation status
    ├─ Engine (semantic command owner, sole ETS owner)
    │    └─ existing Writer (temporary, same recovered Port/flock for its lifetime)
    └─ execution supervisor (Phase 5)
         ├─ scheduler + queue demand coordinators
         └─ trusted per-execution relays + waiting user tasks; bounded outcomes
```

This is a responsibility diagram, not permission to implement bespoke supervision.
Use OTP supervisors/monitors with an explicit runtime-group shutdown protocol.
The guardian must receive writer poison notifications as well as process DOWN;
an additive internal watcher/notification API must publish revocation before
potentially slow cleanup. It must not expose the Port or admission reference to
workers. Preserve Writer's existing temporary child behavior and physical tests.

The Engine is the single **semantic** serialization point. Writer remains the
single **physical** mutation owner. Only Engine holds its post-activation admission
reference. Queue/scheduler processes send intents; neither writes storage nor
updates authoritative indexes. Concurrent user code runs outside these actors.
No second Writer, parallel replay or read-to-write lock handoff is introduced.
The Event/value/transition code bundle stays fixed for a whole generation;
deploy those modules by stopping the engine and doing a fresh full startup.
The existing provider-module fingerprint is not transitive dependency pinning.
Hot code replacement during replay or live interpretation is unsupported, not
something an unchanged top-level codec checksum makes safe.

### 5.1 Startup and state publication

1. Validate complete engine configuration/registry/resource settings without I/O;
   close admission and publish lifecycle `:recovering`, not ready.
2. Engine invokes `Writer.start_recovered_link` with production EventDecoder and
   a pure bounded candidate reducer. Candidate is a map of current domain jobs,
   not all events and not ETS. Enforce retained-job/decoded-state budgets while
   reducing. No public state, registry-driven worker resolution or timestamps
   affect this reduction.
3. Activate once on the same Writer. Receive its candidate/admission reference;
   construct unnamed private ETS tables owned by Engine, validate their internal
   consistency and drop the candidate copy. Account for transient multiple copies
   of candidate plus ETS in the startup memory budget. Retained small sub-binaries
   must not invisibly pin discarded frame-sized backing binaries: detach them or
   account for their backing storage in the conservative retained-state budget.
4. Phase 5 then reconciles recovered executing jobs in bounded batches through
   the durable command path. Every such event is independently valid; a crash
   mid-reconciliation resumes from full replay without double-incrementing an
   attempt or inventing a checkpoint.
5. Publish one generation's readiness only after all required tables and
   reconciliation complete and Writer remains healthy. Enable bounded admission
   and queue demand. Storage activation alone is never engine readiness.

Index construction failure after activation may follow an already-created empty
successor; that is an engine startup failure **after** the Phase 3 activation
boundary, not a claim that pre-activation storage was modified. Return no jobs,
close the whole generation, preserve history, and restart from genesis only.

Handle Phase 3's valid `:terminal` activation result separately: it has no
mutation admission reference and its helper is closed. Do not publish an online
engine or try to reconcile executions in exhausted sequence/segment space.
Return a bounded `:coordinate_space_exhausted` startup diagnosis; offline
inspection may still report fully valid history. Never wrap counters, fabricate
an admission reference, or turn this into a corruption/repair classification.

Explicit initialization is separate: add an initialize-only entry point around
the Phase 2 bootstrap/genesis protocol. Under its lock it refuses an initialized
STORE and never routes through existing-store `open_ready`/successor creation.
It may complete only the narrowly proved unfinished genesis states already
authorized by Phase 2 §12. Explicit bootstrap intent is still required for a
pre-existing empty root; the administrative API name is not permission to erase
or reinterpret a missing-marker history. An already initialized STORE is a
no-Event/no-successor refusal, not a promise that administrative acquisition
performs no directory/lock barriers. Existing-only replay remains untouched.
Normal engine startup always uses existing-only recovery, even immediately after
initialization. Closing an initialization operation and subsequently doing full
fresh recovery is not an offline recovery ticket or a release/reacquire inside
an activation attempt. Missing lock/STORE never triggers this operation implicitly.

### 5.2 Shared transition and commit order

Internal contracts to introduce:

```text
Event.encode(domain_event) -> validated {type, schema, payload} or error
Event.known_type?(type), Event.supported_schema?(type, schema) -> explicit capability booleans
Event.decode_payload(type, schema, payload, limits) -> inert event + consumed bytes
Transition.prepare(previous_job_or_absent, event) -> prepared effect or rejection
Transition.apply(prepared_effect, validated_record_position) -> next domain job
Projection.replace(previous_job, next_job, index_context) -> coherent index update
Engine.command(generation, permit, intent, expected_revision) -> acknowledged result/error
```

Replay uses the same `prepare/apply` functions inside its pure map reducer.
Live processing validates all business preconditions and capacity before I/O,
encodes one Event, obtains Writer's matching mode-verified receipt, binds its actual
sequence/position to the prepared effect, updates all indexes, then replies or
releases a worker. Only Engine produces Events; no public raw Event append API.
Binding the receipt must not discover a previously unchecked business rejection.
An unexpected receipt or projection failure after append invalidates the entire
generation and is unknown outcome, never rolled back or reported as no-write.
EventDecoder and candidate reducer budget failures use the existing
`{:error, {:resource_limit, key}}` callback contract with fixed internal keys;
they must not masquerade as unsupported schemas or invalid job transitions.

All authoritative reads initially go through Engine, including `get_job` and
selection. ETS tables are `:private`, unnamed, without heirs. Updating multiple
tables is not claimed atomic to arbitrary ETS readers; no readers receive table
IDs, and Engine processes no command/read between update steps. Death removes
the whole view. Direct concurrent read publication/RCU is not on the critical path.
Lifecycle `status` is served by the guardian while Engine is blocked; counters
there are bounded snapshots with explicit freshness, not a synchronous call into
Writer or a claim of current authoritative job state. Job reads use the normal
bounded client admission path and may time out while Engine is doing storage I/O.

| Index | Key/value and role |
| --- | --- |
| JobIndex (`:set`) | Job ID → current domain job, immutable insertion definition, revision/cycle/attempt/execution facts |
| QueueIndex (`:ordered_set`) | `{queue_key, eligible_at, available_event_sequence, job_id}` → ID; only available jobs eligible for this registry and with no previous local callback still alive |
| SchedulerIndex (`:ordered_set`) | `{due_at, job_id}` → ID/revision for scheduled/retryable jobs |

Secondary indexes contain IDs and bounded keys, not copies of args. Every update
removes the precise old keys before installing the new ones. A pure independent
test oracle derives all keys from JobIndex plus explicit registry/live-task
context and compares them after every generated event/runtime eligibility change.
Disabled queues/unmapped workers affect dispatch eligibility only, not
the durable job state or semantic decoding. Count/report blocked jobs; never
drop them, burn their attempts, or scan past unbounded blocked heads on every poll.
Configuration changes requiring index rebuilding occur by controlled restart in
the first release, not mutable registries during replay.
After a prior callback's confirmed death, restore any now-eligible ready key via
Engine's serialized runtime projection; this does not change durable job state.
Do not repeatedly scan past ineligible live-task heads to find other runnable jobs.

### 5.3 Bounded admission and lifecycle revocation

Require a bounded generation-local permit pool **before** sending argument-bearing
requests to Engine. A GenServer mailbox length check or call timeout is not a
capacity mechanism. The concrete gate may use fixed-slot ETS/atomic reservation
with monitored owners; its reserved → submitted → completed/revoked state machine
and race tests belong to Phase 4. Submitted permits are not released on caller
timeout. Unsubmitted abandoned permits are reclaimed safely; late old-generation
submissions cannot append. No hidden unbounded waiter queue.

Use separate budgets for client operations, scheduler/demand messages, and worker
outcomes. At most one outstanding demand per queue; at most one normalized outcome
per active task. Reserve enough control admission/bytes to settle active attempts
even when insert admission is saturated. Bounded byte limits accompany count limits.
Engine must not monitor/link the arbitrary user callback process directly: raw
exit/DOWN reasons can contain huge terms. A trusted per-execution relay receives
those reasons, produces a bounded outcome and confirms actual callback death;
Engine monitors that relay and retains its execution/child identity. Unexpected
relay loss invalidates the generation unless child termination is proven through
the trusted lifecycle protocol. Never forward raw reasons to Engine or default
logs. The relay/supervisor may receive an application-sized reason; this is not
a claim that all BEAM delivery of arbitrary worker terms has a hard byte cap.
This bounds Tay's cooperative protocol, not arbitrary hostile messages or arbitrary
memory allocated by application worker code in the same BEAM.

On Writer poison/death, Engine/index-owner failure or protocol contradiction:
guardian closes the generation gate, invalidates readiness, stops queue demand
and runtime tasks, and discards all indexes. Outstanding requests become unknown
or unavailable according to whether submission occurred. A fresh attempt is an
explicit whole-engine restart, never a restart of Writer under old ETS/queues.
Wait for known old local tasks to terminate before releasing a new local generation.
A stalled helper may retain its OS lock; never delete the lock to make progress.

Execution tokens fence Tay state, **not external services**. A dying BEAM or
external child may continue a side effect briefly while a new independent owner
starts. Queue concurrency is enforced within a healthy engine generation; strict
cross-crash external mutual exclusion requires application-side fencing and is
not promised by this design.

## 6. Phase 4 — durable job core

### 6.1 Exact scope

Implement the approved Event representation and all pure lifecycle transitions;
production EventDecoder; bounded pure recovery candidate; Engine lifecycle and
private ETS indexes; explicit initialize-only operation; stable ID construction;
durable insertion, lookup and same-ID reconciliation; mandatory bounded client
admission. No workers run in this phase, even if replay encounters an executing
job in a conformance fixture. Tables/model may represent future states without
exposing their live command producers yet.

### 6.2 Public API introduced

```elixir
Tay.child_spec(engine_options)  # explicit host supervision; not automatic app startup
Tay.start_link(engine_options) # same lifecycle, usually via the child specification
Tay.Job.new(worker, args, options \\ []) # {:ok, uninserted_job_with_id} | {:error, validation}
use Tay.Worker, key: "mail.send.v1", queue: :default, max_attempts: 10
# adds new/1,2; perform/1 unchanged; key is stable deployment configuration
Tay.insert(job_or_builder_result, options \\ []) # {:ok, job_view} | {:error, error}
Tay.get_job(job_id, options \\ []) # {:ok, job_view} | {:error, :not_found | error}
Tay.status(options \\ []) # bounded lifecycle/capacity state, not storage handles
Tay.Storage.initialize(storage_options) # explicit administrative operation, no Events
```

Options include a trusted instance name (default one Engine), expected revision
where relevant later, and finite caller timeout. `insert` accepting a builder
result preserves the proposed `args |> Worker.new() |> Tay.insert()` style.
Direct `%Tay.Job{}` construction remains non-persistent; incomplete definitions
are rejected before admission and no default fake successful job is fabricated.

Use `Tay.Engine.Config` for engine-only options (registry, explicit sync assertion,
limits), reusing base path/queue validation without teaching the physical codecs
about queue policy. The existing application remains storage-free by default;
existing foundation tests stay meaningful. A default instance may consume the
configured `:tay` path/queues; production requires that explicit configuration.
No silent dev path or mode fallback is accepted by a production Engine.
Pass engine-specific settings through the explicit child/start options, not new
top-level `:tay` application keys that the existing `Tay.Config.load/0` would
reject. Keep the foundation path/queue configuration contract intact.

Errors distinguish invalid input/conflict, known pre-I/O capacity refusal,
unavailable generation, and submitted unknown outcome. Include stable job ID
and bounded correlation context, never args/stack dumps/native references.

### 6.3 Internal components and file boundaries

Add `lib/tay/event.ex`, `lib/tay/event/value.ex`, `lib/tay/event/v1.ex`,
`lib/tay/job_id.ex`, `lib/tay/error.ex`, `lib/tay/state/transition.ex`,
`lib/tay/state/projection.ex`, `lib/tay/state/job_index.ex`,
`lib/tay/state/queue_index.ex`, `lib/tay/state/scheduler_index.ex`,
`lib/tay/engine.ex`, `lib/tay/engine/config.ex`, `lib/tay/engine/supervisor.ex`,
`lib/tay/engine/lifecycle.ex` and `lib/tay/engine/admission.ex`.
Extend `lib/tay.ex`, `lib/tay/job.ex`, `lib/tay/worker.ex` for actual runtime APIs,
and `lib/tay/storage/writer.ex` for initialize-only operation and bounded
poison/lifecycle notification. A small `lib/tay/storage.ex` administrative facade
may expose initialization without raw mutation handles.

No native/disk codec/Recovery API change is expected. Any discovered need to
change those contracts requires a separate reviewed amendment. Document new
APIs in README/architecture and a phase report; add independent semantic fixtures
under `test/fixtures/events/v1/`, new tests under `test/tay/event/`,
`test/tay/state/`, `test/tay/engine/`, and dedicated support modules.

### 6.4 Persistence and transitions

Only new live `job_inserted` records are produced; all six schemas and pure
transition paths have fixtures/unit/property coverage. Exact insert order is
validate/prepare → append + strict barriers → coherent ETS → response. No
write-mode receipt may be relabeled durable. Same-ID/same-definition reconciliation
does not append, consume a sequence or resurrect a terminal job.

### 6.5 Crash and recovery semantics

Use §5 startup unchanged. Failure before append leaves no job; full append after
lost ACK may recover a job; partial append refuses activation. A crash between
any two ETS writes or between projection and reply destroys the generation;
replay restores the complete stored effect. Missing production provider, bad
payload or invalid transition fails before activation with all bytes preserved.
ETS rebuild never invokes a worker. No raw-Writer retry path exists.

### 6.6 Concurrency and ownership

Engine serializes job state, Writer serializes bytes, guardian fences generations.
Tables belong to Engine, not individual queues. Synchronous recovery stays in
Writer with a pure accumulator; no ETS/Port ownership transfer. Client permits
bound queued data even while a slow sync/rotation blocks Engine.

### 6.7 Invariants

F1–F6 and J1–J6, specifically acknowledged insertion survives full valid replay,
no partial public indexes, no storage-free fake success, stable same-ID behavior,
and no same-ID divergent overwrite. This establishes TAY_PLAN A/B/F/G/I/J at
the first real job boundary; it does not yet claim execution invariant H.

### 6.8 Tests and fault injection

- Independently pinned bytes per type/schema, truncations, all unknown/reserved
  value tags, duplicate/out-of-order keys, extra/missing fields, UTF-8 and numeric
  limits, exact consumption, ETF-looking inputs, fresh-VM atom/module independence.
- Generated valid/invalid transition sequences with independent map/index oracle;
  encode → full physical/semantic recovery equals live effects, including all
  future attempt/cancel/retry states before their runtime producers exist.
- Same-ID concurrent insert, ID collision, definition conflict, lost response,
  lower insertion limit after acceptance, stale revision and absent-worker lookup.
- Kill at pre-append, full-write/pre-sync, post-sync/pre-projection, each individual
  index update and pre-reply; compare full storage evidence on every refusal and
  all externally observed successful inserts after restart.
- Poisoned-but-alive Writer revokes Engine; helper/Engine death removes readiness;
  late permits/caller death/timeouts cannot cause unbounded queues or stale writes.
- Candidate/state-budget failure before activation; ETS allocation/publication
  failure after activation is classified correctly, with no leaked readiness.
- Valid exhausted coordinate space returns no online engine/admission; near-limit
  admission accounts for remaining sequence/segment headroom without wrapping.
- Initialize-only refuses existing STORE without successor publication; recovery
  of missing root/lock/STORE never initializes; independent owner contention.

Run unchanged Phase 1–3 suites, Linux strict-sync and macOS development tests.
At exit deliver exact commands/results, fixture hashes and live/replay model
equivalence evidence. No release claim based only on codec round trips.

### 6.9 Explicit non-goals

Worker execution, active-attempt reconciliation writes, scheduling timers,
cancellation/retry public commands, priority/uniqueness, result storage, arbitrary
term args, multi-instance guarantees, snapshots, retention, batching/group commit,
physical repair or scanner/CRC optimization.

### 6.10 Dependencies and exit

Depends on accepted Phase 3 and approval of the Event/model/ownership gates in
§12. Exits when durable insert/lookup/restart/reconciliation and all private-index
invariants pass. Phase 5 consumes this complete model and commit path; Phase 6
capacity/package design can proceed concurrently without changing it.

## 7. Phase 5 — complete execution lifecycle

### 7.1 Exact scope

Build supervised execution across configured queues, bounded demand and running
slot tracking, durable start authorization, normalized outcomes, stored retries,
scheduled availability, interrupted-execution reconciliation, executing/queued
cancellation and revision-checked manual retry as one cohesive implementation.
This replaces original Phases 6–9; none of those features is deferred until after
the first production release.

### 7.2 Public API introduced

`Tay.cancel(job_id, options \\ [])` and `Tay.retry(job_id, options \\ [])`, returning
job view or bounded conflict/unavailable/unknown outcome. Support expected opaque
revision. Activate dispatch for Phase 4's persisted insertion `scheduled_at`
option and stored timeout/retry policy. Worker callback results remain exactly
`:ok | {:ok, term} | {:error, term}`; no new user callback is required for replay,
backoff or error serialization. Extend `status` with queue capacity, blocked-worker
counts and pending reconciliation, without exposing individual secrets.

### 7.3 Internal components and files

Add `lib/tay/execution/supervisor.ex`, `queue.ex`, `executor.ex`, `scheduler.ex`,
`relay.ex`, `retry.ex`, `outcome.ex`, `clock.ex` and `registry.ex` under
`lib/tay/execution/`. Queue owns bounded demand, not worker state truth; Executor
runs user code in a supervised waiting task outside Engine. Its trusted relay
isolates raw outcomes/exit reasons from Engine and confirms callback death.
Engine retains relay/child identity, execution-token and slot facts. Add command
handling to Engine, lifecycle integration to its supervisor/guardian and public cancel/retry delegates
to `lib/tay.ex`. Transition/schema changes should not be needed after Phase 4's
joint model approval; a discovered mismatch returns to design review, not a
quiet schema-1 alteration. Add `test/tay/execution/`, Engine lifecycle/integration
tests and `test/support/execution_helpers.ex` with fake clock/barriers.

### 7.4 Persistence and runtime transition sequence

For each execution, reserve a queue slot and create a supervised relay plus user
task which initially waits without invoking user code. Engine monitors the relay;
the relay monitors the user task. Engine rechecks job/revision, eligibility and
credit, durably commits `job_started`, projects it, then sends
the generation/execution authorization to that exact task. The task checks its
generation's liveness before entering `perform/1`. No worker call is made from
replay, the queue coordinator, Engine, or Writer.

There is no way to make callback entry atomic with a durable start. A death in
between leaves an interrupted start, handled under §4.3. A task which dies before
start persistence consumes no logical attempt; after persistence its start must
be settled even if user code never ran. Task-supervisor startup errors are
infrastructure failures, not successful dispatch.

The relay normalizes and sends at most one bounded outcome. Engine matches exact
generation, execution token and executing revision before committing one
`job_finished`. Keep the slot reserved through outcome durability/projection and
task death. Late duplicate results/DOWN/timers cannot settle twice or release a
slot twice. Errors in Tay persistence/projection are infrastructure failures,
never synthetic worker failures that continue appending on a poisoned store.
Regardless of durable job state, a new local start also requires that no prior
callback for that job remains alive. Keeping only a queue slot reserved is not
enough: a different free slot must not admit its retry while the old callback
is still terminating. Test this explicitly for timeouts and fast retries.

Measure the stored timeout using a monotonic deadline starting at callback
release, not while waiting for start persistence. Timeout settlement and task
termination follow the same durable-outcome/token/death protocol; a late success
cannot replace the chosen timeout. Observed worker errors/exits and timeouts
consume a logical failure attempt. Lost Engine/Writer/relay infrastructure uses
whole-generation shutdown and the interrupted-execution policy on fresh recovery.

Scheduler reads bounded earliest-due keys, commits `job_available` per due job,
then installs ready keys. It never changes states in ETS alone. Retries use the
same scheduler, not a separate timing mechanism. Choose due jobs in deterministic
`{due, id}` order; ready selection uses §5's queue key. Across queues use bounded
round-robin demand so one busy queue cannot monopolize Engine. No priority API
or global completion-order guarantee is implied.

Wall clock determines eligibility and is rechecked at start, including after
backward clock steps. Monotonic timers only trigger bounded rechecks; cap a wake
interval (recommended at most one second) rather than scheduling one enormous
unvalidated timer. Clock forward steps can make jobs due; backward steps delay
them. “Not early” means not before the stored UTC deadline according to the
observed system clock, not proof against a misconfigured real-world clock.
Replay never consults current time to change the reconstructed state.

### 7.5 Crash/recovery and cancellation

Pure replay reconstructs all complete Events, including unacknowledged outcomes.
Only after activation does startup settle unmatched executing tokens as
interrupted, persist their chosen due times, and rebuild coherent ready/due state
before dispatch. Complete completion/cancellation suppresses another run even
when its previous sender did not see success. A torn outcome stops the entire
store; it is not permission to treat the job as retryable and append past it.

For cancel versus completion, Engine serialization and expected revision choose
one first effect. Durable cancel prevents future retries; termination is best
effort and slots remain occupied until death. External effects may already have
happened. Manual retry of discarded work creates a new cycle, not a new job ID
or reuse of a physical start token. An interrupted new cycle remains reconstructable
even if the caller never saw manual-retry success.

### 7.6 Concurrency/ownership

Engine is the only slot/attempt authority. Queue restart cannot reset concurrency
while older tasks run; it reestablishes demand against Engine's live task map.
Scheduler restart re-arms from indexes, not a historical scan. User worker death
is isolated and generates a normal attempt failure. Engine/Writer generation loss
revokes the whole runtime group. Stale task messages are denied even if a later
attempt has the same logical attempt ordinal; physical tokens are different.

No busy polling, per-job scheduler process, unbounded prefetch or executor result
backlog. A stalled sync can delay progress but cannot create extra slots or
release a worker early. Arbitrary worker-created unlinked processes, NIF hangs
and external side effects are application responsibilities, not a Tay sandbox.

### 7.7 Invariants

All F/J invariants, especially durable existence before callback, one admitted
current execution token per job, per-generation queue concurrency, durable
outcome/retry atomicity, stale-result fencing, clock-free replay and no cancelled
job resurrection. `max_attempts` semantics are those explicitly approved in
§4.3, not silently altered during scheduler implementation.

### 7.8 Tests and fault injection

- Barrier-controlled start at every boundary: slot reservation/task wait/start
  append/sync/projection/release/callback entry. Prove no pre-authorization side
  effect and safe interruption accounting, including repeated restarts.
- Side effect observed externally then crash before completion; duplicate effect
  is permitted/expected, lost job or forged completion is not. Keep external ACK
  and side-effect oracles separate from Tay's stored history.
- Full/torn/lost-response outcome, retry and cancellation records; all settled
  events survive appropriate restart and all incomplete suffixes preserve bytes.
- Fake-clock forward/backward jumps, equal due times, far-future deadlines,
  retry arithmetic caps/jitter, scheduler restart and no early start.
- Cancel before claim, during waiting task, during running work, concurrent with
  success/failure and after timeout; manual retry races/repeated unknown results;
  compare live/replayed state and late-result denial.
- Queue/scheduler/task/Engine/Writer/helper kills independently; no forgotten
  running slots, no oversubscription, no callback-induced Engine crash and no
  Writer reuse with old ETS. Test creator/guardian loss too.
- Huge return/exit reasons, relay death and delayed task termination: no raw term
  forwarded/logged, no leaked credit, and no retry overlapping its old local task
  merely because another queue slot is free.
- Saturate inserts while all workers return outcomes and schedules become due;
  prove count/byte bounds and reserved completion/control progress.
- Missing/renamed workers and removed queues do not corrupt replay or discard
  jobs; restored mappings make the same persisted keys dispatchable after restart.
- Generated command/clock/crash schedules against an independent state-machine
  oracle, including logical attempts versus physical starts and manual cycles.

Extend the unchanged Linux strict-sync, macOS development, native fault and
independent-BEAM suites with real job Events. Report all faults as process/syscall
tests, not power-loss certification.

### 7.9 Explicit non-goals

Cron, uniqueness by args, priorities, batches/workflows, distributed workers,
exactly-once side effects, arbitrary worker-result persistence, hot registry
reload, live concurrency reconfiguration, pause persistence, retention/compaction,
automatic tail repair, and throughput changes to storage protocols.

### 7.10 Dependencies and exit

Requires Phase 4 commit/projection/admission/model acceptance. Exits with every
original execution/retry/schedule/cancel/manual-retry criterion demonstrated and
one integrated failure matrix. Phase 6 must still qualify packaging, capacity,
operations and supported deployment claims; this phase alone is not production.

## 8. Phase 6 — production operations and release qualification

### 8.1 Exact scope

Finish bounded lifecycle controls, safe diagnostics, deployment documentation,
release packaging and automated platform verification. Measure retained-history
replay/rotation/dispatch performance and memory; establish the supported production
envelope. Run end-to-end crash/restore/upgrade drills and independent adversarial
review of the complete implementation, not just isolated storage modules.
This is a release qualification phase, not delayed basic feature testing.

### 8.2 Public/operational API introduced

```elixir
Tay.pause_queue(queue, options \\ [])
Tay.resume_queue(queue, options \\ [])
Tay.drain(options \\ [])
Tay.stop(options \\ [])
Tay.restart(options \\ []) # explicit fresh generation, never replay of an RPC
```

Pause stops new claims after its accepted barrier, not running side effects.
Pause state is volatile and resets to explicit startup configuration, including
`start_paused`; do not claim it survives restart. Drain rejects new inserts and
claims, permits settlement of already-started work, and returns only when those
tasks are dead and their accepted outcomes are projected/durable. It does not
mean every queued/future job has executed. Timeout leaves the engine draining,
not secretly resumed. Forced stop is explicitly distinct from a successful drain.
Normal stop need not seal an active segment and must not add a needless torn-footer
window. Restart never repairs a store or replays pending client requests.

Add `mix tay.storage.init` around the initialize-only operation and
`mix tay.storage.inspect` for locked existing-only full physical/semantic diagnosis
without activation. No `--force`, `repair`, arbitrary offsets or raw mutation
command. An online `Tay.status` remains a bounded runtime report, not an offline
consistent backup or an activation certificate.

### 8.3 Internal components and files

Extend Engine lifecycle/admission/config for controls and measurable counters;
add `lib/tay/diagnostics.ex`, `lib/mix/tasks/tay.storage.init.ex`,
`lib/mix/tasks/tay.storage.inspect.ex`. Add/extend release checks in `mix.exs`,
package metadata and `.github/workflows/`, plus `bench/` and dedicated system-test
harness files. Document support in `docs/operations.md`, `docs/compatibility.md`,
`docs/production-limits.md`, README and a release verification report.

No required byte-format/native protocol change. If measurements show CRC cost
prevents even the agreed bounded workload, a byte-identical optimized CRC backend
may be proposed as a separately reviewed implementation subtask here, guarded by
all fixed vectors/oracles/chunk properties and baseline backend parity. Removing
full validation passes, caching unproved sealed histories, group commit and
rotation-protocol changes are not authorized performance shortcuts. If needed
to meet a larger target, they change the scope/critical path explicitly.

### 8.4 Persistence/state transitions

No new operational Event types, manifest or persistent pause/config metadata.
Graceful controls use the already-approved job Events where attempts need settling.
Capacity controls reject new insert/start work before I/O and preserve enough
reserved headroom for active outcomes and required rotation envelopes. Track
canonical bytes/entries, remaining sequence/segment coordinates and retained
jobs/definition bytes; do not repeatedly
scan history to compute capacity on each insert.

No job/state eviction is performed merely because it is completed or old.
Every ID needed for insertion reconciliation remains retained. Capacity limits
are operational admission/recovery budgets, not altered physical validity.
Increasing resources may allow progress; deleting segments/jobs is not a remedy.
Control headroom cannot protect against actual ENOSPC, device failure or unlimited
repeated crashes; those remain fail-closed infrastructure errors.

### 8.5 Crash/recovery and backup/restore scope

Document a cold backup/restore procedure only: stop all engines against that store,
exclude other writers, copy the **whole** store including STORE, every canonical,
retained recognized stages and the existing lock file, to a separate destination.
Never copy only sealed files or omit an active/lock file. No live snapshot claim.
Never overwrite the only copy of a failed store.

Restoring file bytes is not by itself durable publication: the external restore
procedure must sync **every restored history file**, its directories and required
ancestor entries before claiming a durable restored store. Existing activation's
highest-file/marker barriers are not proof that newly copied older sealed files
were synced. Qualify and test the selected offline restore procedure on the
supported Linux volume before documenting it as supported; no unsynced `cp`
recipe is an acknowledged-durability guarantee. Verify the destination with
existing-only full semantic inspection and then fresh recovery/activation; it
must contain its lock and all required genesis history. Different copied inodes
are normal between stores/sessions, not permission to change pinned identities
inside a session. Backup checksums/catalogs are external artifacts, never Tay
recovery anchors or authority for suffix truncation.

An older backup has an explicit RPO: later acknowledged work may not exist in
it, and previously completed external effects may run again. That is operator
disaster recovery, not proof of preserved latest history. Do not run source and
restored copies concurrently; cloned STORE_ID is not distributed fencing.
When canonical history is torn or corrupt and no acceptable backup exists,
report an operational blocker and preserve all evidence. No prefix salvage
tool is bundled into this release under another name.

### 8.6 Concurrency/ownership

All runtime controls serialize against Engine and the generation gate. Draining
does not release flock while work may still append. Independent inspection gets
busy against a live owner rather than racing it. Explicit restart closes/revokes
the old local runtime group and requires fresh full recovery; no inherited ETS
or writable reference. Offline operations require exclusive ownership and never
delete/recreate the lock to resolve a busy condition.

### 8.7 Invariants

All F/J invariants must survive release packaging and operations. Success and
unavailable/unknown outcomes remain distinguishable under overload/shutdown.
Documentation must not promise more durability, repair availability, capacity,
privacy or external fencing than the implementation/test evidence supports.

### 8.8 Tests, fault injection and release gates

- Run formatter, compile with warnings as errors, full suites, fixed fixtures,
  native packet tests, macOS development path, Linux strict sync on an explicitly
  checked supported local filesystem, ASan/UBSan and opt-in 1 GiB/many-segment
  cases. Preserve all existing assertions; record exact versions/commands/skips.
- A disposable external harness records acknowledged job IDs and callback effects;
  kill at every cross-layer commit/start/outcome/cancel/activation boundary.
  Successful recovery retains every ACK covered by the strict storage assumptions;
  incomplete history always preserves evidence and refuses activation.
- Drain/timeout/force-stop/late-result/control saturation matrix, including a
  poisoned-but-alive Writer and slow filesystem while outcomes are pending.
- Restore drill with full-history copying and explicit file/directory barriers;
  missing lock/file/STORE, stale stages, corrupt archive, wrong schema and older
  backup are classified honestly. No repair/salvage counts as a passing restart.
- Upgrade fixtures from every supported Event schema; unsupported newer pair
  stops without mutation, including before highest-sealed successor creation.
  Test safe code rollback refusal; physical v1 readability is not downgrade
  semantic support. Neither fixture manifests nor old schemas are rewritten.
- Release artifact in a separate consuming Mix application with no repository
  test support, correct native executable permissions/architecture, no runtime
  dependency on a source checkout, no fault opcode/API and no test decoder.
  Building may require the documented C11 compiler; running a built release
  must not compile a helper on the production host unexpectedly.
- Benchmark realistic args, sync insert/start/finish latency, rotation pauses,
  queue fairness and scheduling lag at idle and saturated insertion load,
  bytes/job, transient candidate+ETS memory, and replay at 1/10/100-segment scales.
  Trace that job lookup/selection uses indexes and that existing storage scans
  appear only where disclosed. Include lowered budgets and reserve exhaustion.
- Publish a deployment profile with measured maximum retained jobs/argument bytes,
  stored history/segments, concurrency, required free disk and RAM, maximum tested
  restart time and observed p95/p99 operation/rotation latency. A test run that
  exceeds approved recovery deadlines is not a supported production profile.
- Bound error/telemetry fields; verify args/results/secrets never enter default
  logs and dynamic persisted strings do not increase atom count. Credentials and
  args remain plaintext on disk; encryption/access controls are deployment concerns.
- Independent adversarial review signs off invariants and the operation matrix.
  Real hardware power-cut/device certification is separately identified, never
  inferred from process kills or a Btrfs filesystem-type check.

Numeric runtime limits may start as conservative engineering defaults (for
example 256 KiB new args, 1 MiB insertion payload, 64 client permits with a
separate byte budget, due batches of 32 and bounded active-outcome slots), but
they are **not** a production capacity claim or semantic hard bounds. Final
defaults and the advertised workload envelope must be approved from measurements;
do not lower replay capability to the insertion defaults. Phase 3 operational
defaults remain unchanged unless separately configured by the operator.

### 8.9 Explicit non-goals

Snapshots, manifests, segment deletion/compaction, automatic repair, live backup,
anti-rollback/replication, added durability modes/platforms, application-level
uniqueness, dashboards/exporters, priority/workflow/distributed features, and
unqualified unlimited uptime/history throughput promises.

### 8.10 Dependencies and exit

Depends on integrated Phase 5 plus operational design work begun alongside Phases
4/5. Exit is the signed, measured first-production profile, complete crash/fixture
evidence, tested install/start/stop/restore/upgrade procedures and resolved release
blockers. Select the actual release version then; Git phase tags alone do not
establish package version or production readiness.

## 9. Coordinated crash review checklist

This matrix is the shared acceptance spine across all three phases, not tests
deferred exclusively to Phase 6:

| Boundary / trap | Required result |
| --- | --- |
| Accepted permit, caller disappears before/after submission | Reclaim only safe unused capacity; submitted work may commit; no false no-write claim |
| Insert sync succeeds, Engine dies before any/all index updates or reply | No stale public view; same-ID complete event replays; caller may have unknown outcome |
| Callback runs before start sync | Forbidden by waiting-task release protocol |
| Durable start, task never enters worker | Interruption is persisted after activation; same logical attempt, new physical token |
| External effect, lost/torn completion | Duplicate effect possible; complete outcome replays; torn outcome blocks store without repair |
| Failure known, retry time not yet persisted | Still executing until one complete outcome Event; no failure/retry two-record gap |
| Cancel races with start/result/DOWN | One serialized transition wins; no outcome from an obsolete token or slot double-release |
| Registry/module/config differs on restart | Stable payload decode unchanged; missing mapping blocks dispatch rather than dropping jobs |
| Old task/queue/timer survives into new generation | It has no admission; local old tasks must be stopped; external effects are not fenced by Tay tokens |
| Retry becomes due while its timed-out callback is still alive | Keep it out of ready eligibility until confirmed death; another free slot is not permission to overlap |
| Valid terminal sequence/segment space | Preserve valid diagnosis, no online engine or mutation reference; never wrap/rebase |
| Unknown semantic Event in earlier sealed history | Full engine unavailable; no activation/successor/partial indexes |
| Budget admits history but not projected state | Fail without public state; never trim history/state to fit |
| Disk reserve, footer or directory barrier fails | Poison and stop; no completed/cancelled/insert success fabricated from ETS |
| Changed policy/clock alters past replay | Forbidden; persist choices, keep pure transition interpretation fixed |
| Backup missing active/lock or unsynced older sealed copies | Not a qualified restore; no bootstrap/rebase workaround |

## 10. Parallel design, sequential implementation and review boundaries

```text
                    Shared contract review (this roadmap + Event conformance)
                       /                    |                      \
          Phase 4 detailed design   Phase 5 detailed design   Phase 6 ops/test design
                       \                    |                      /
                        agreed model / error / ownership contracts
                                        |
                         implement + accept Phase 4
                                        |
                         implement + accept Phase 5
                                        |
                         integrate + qualify Phase 6
                                        |
                           first production release
```

Parallel **design** is safe for Event/schema vectors, pure state/index modeling,
execution race analysis and release harness/operations planning, once shared
terms are written down. Event designers and execution designers must jointly
review attempt accounting, cancellation, manual retry and unknown outcomes;
those are not independent semantic decisions. Platform/package review and
adversarial fixture/harness design can proceed against the current frozen formats.

Implementation of the correctness-bearing path is sequential: production Event
support → transition model/commit projection → execution protocol → release
qualification. Within an authorized phase, independent fixture/oracle tests,
documentation and packaging preparation can be implemented in parallel if work
ownership is explicitly assigned; this RFC requests no agents or implementation.
Do not merge live executors against fake insertion, stub durability, mutable test
providers or a second provisional state machine. Completing Phase 4 does not
implicitly authorize Phase 5 source changes.

Recommended review cuts, without inventing more phases:

- Phase 4: freeze Event conformance; review pure transition/property model; review
  commit/index/admission/lifecycle integration; full acceptance.
- Phase 5: review start/outcome/restart protocol as one unit; add scheduler and
  administrative producers against it; full race/fault acceptance.
- Phase 6: integrate controls/packaging, run the capacity/crash/platform matrix,
  then release review. Performance changes need their own evidence, not broad
  permission to remove checks.

Acceleration comes from one jointly reviewed semantic model, one commit path,
one scheduler for delay/retry, one generation/attempt protocol, reuse of the
existing native fault harness and shared acceptance matrix, and designing
operational requirements before feature implementation finishes. It does not
come from batching away required fsync, skipping replay passes, removing native
sanitizers or converting unknown outcomes into retries.

## 11. Shortest critical path and deferred work

The shortest path meeting TAY_PLAN's production-core definition is:

1. Approve regrouping and close the new semantic/ownership gates below, with
   the Event literal conformance appendix. No revisit of G1–G6.
2. Complete Phase 4's production decoder + pure model + insert/replay/private ETS
   + coherent generation lifecycle and bounded admission.
3. Complete Phase 5's integrated start/outcome/retry/schedule/cancel/manual-retry
   protocol. A “worker ran once” demo is not a shortcut to this exit.
4. Complete Phase 6's already-designed release harness, operations, platform
   package checks and measured bounded production envelope.

The critical-path blockers are Event/policy approval, correct cross-layer commit
and generation fencing, complete lifecycle fault coverage, and a defensible
workload/deployment profile. Calendar estimates would be speculative without
staffing and target workload; relative size is Phase 4 high semantic risk,
Phase 5 high concurrency risk, Phase 6 substantial qualification work that can
be prepared early.

Snapshot/manifest/retention remains original Phase 11, after this release, and
must prove coverage before any deletion or replay re-anchoring. It can become
the next production milestone if measured history growth makes the bounded
profile unsuitable. It is not smuggled into Phase 6 as “cleanup.” Automatic
torn-tail repair is a separate protocol with its own evidence obligations and
may require new independently reviewed metadata; nothing here authorizes it.
Advanced orchestration/uniqueness remains original Phase 12. No wire-format
change is currently necessary for this three-phase path.

## 12. New approval gates and stop point

These are **new** review decisions, not reopened Phase 3 G1–G6:

| Gate | Recommendation / decision required | Must close before |
| --- | --- | --- |
| R1 — regrouping and production target | APPROVED: three phases 4–6; all original core features; bounded Linux strict-sync workload with explicit fail-closed tails/no compaction | Resolved architecturally; implementation still requires authorization |
| R2 — production Event contract | Fully specified in the [Event v1 appendix](event-v1-contract-appendix.md), including literal frames/hashes; awaiting approval | Any production Event codec or durable job write |
| R3 — lifecycle semantics | APPROVED: atomic outcome+retry; interrupted executions reuse a logical ordinal with fresh physical token; executing cancellation fences before best-effort kill; manual retry rules/cycles; same-ID insertion reconciliation | Resolved; exact policy/schema constants are in the R2 appendix |
| R4 — engine/API ownership | APPROVED: explicit engine child, pure recovery candidate then private Engine-owned ETS, one semantic commit owner, bounded permits, poison notifications and whole-generation revocation/restart | Resolved architecturally; implementation still requires authorization |
| R5 — operational release envelope | Accept bounded history/RTO, no automatic repair/live backup; approve concrete measured limits, drain/restore procedures and package/platform evidence | Production release; design can proceed in parallel |

R2's appendix is intentionally a pre-code long-lived-format review, not authority
to improvise missing enum values, float behavior, required fields, error caps or
policy defaults during implementation. If a proposed value profile is rejected,
settle its replacement before Phase 4 rather than shipping an interim format.

The original roadmap preparation changed only this document. Subsequent approval
reconciliation adds its linked Event appendix, not implementation source, tests,
fixtures, dependencies, configuration, historical RFCs or TAY_PLAN changes.
Baseline test counts (276 macOS / 283 Linux, sanitizer and large-test
results) are historical evidence in the Phase 3 report, **not rerun or newly
claimed here**. Verification for this artifact is document consistency, local
links, whitespace and a documentation-only worktree diff.

**Stop for roadmap and long-lived-contract approval. No Phase 4–6 implementation
is authorized by this RFC.**
