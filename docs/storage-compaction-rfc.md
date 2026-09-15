# Storage compaction RFC

Status: Store-v2 Phase A/B qualified; Phase C implementation and the bounded-retention manifest amendment approved.

## Recommendation

Do not compact a v1 store by copying a subset of Event v1 records, deleting
segments, or renumbering records. Add this only through an explicitly approved
Store v2: immutable generations selected by a checksummed current pointer, and
an explicit canonical job-snapshot format. The first implementation should be
manual, single-owner, stop-the-world, with deferred reclamation and
`terminal_retention: :infinity` only while its correctness is qualified. A
production-complete Tay must instead compact automatically under an enabled,
policy-driven, bounded terminal-retention configuration.

This is required by the present format, not a preference for a more elaborate
design. Event v1 is a transition log: noninsert events embed predecessor
physical sequences in `expected_revision`, `cycle_token`, and
`execution_token`; `Transition.apply/2` makes the current record sequence the
revision; Reader requires every record sequence globally contiguous. Dropping
records leaves invalid gaps. Renumbering changes those embedded references.
Rewriting them changes frozen Event history and still does not encode a job in
fewer events. The latest event alone also omits the immutable insert definition
and may omit schedule, retry, attempt, diagnostic, cycle, and execution facts.

## Evidence and existing contract

The requested `TAY_PLAN.md`, storage RFCs, phase/qualification reports, and
`production-limits.md` are absent from this checkout. This RFC relies only on
the actual checked-in contracts: `docs/storage.md`, `docs/compatibility.md`,
`docs/operations.md`, source, tests, and fixtures. That missing evidence must
be resolved before a release claim; it is not filled in by assumption.

The current durable lifecycle is:

1. `STORE` is an immutable 28-byte v1 identity marker (STORE_ID), not a
   manifest/checkpoint. Canonical segments are `segments/%020d.tay`, IDs begin
   at 1 without gaps, and headers/footers carry the same STORE_ID.
2. Record v1 has CRC32C framing and a globally consecutive sequence. Sealed
   segments have checked footers; only the highest segment can be active.
   Maximum segment size stays 1 GiB.
3. The Writer GenServer is the single storage writer. Its native helper alone
   owns flock and writable FDs. Append writes then fsyncs in `:sync`; uncertainty
   poisons the connection. Rotation stages, writes, syncs, closes, renames, and
   directory-syncs a successor before opening it. Sealing appends/syncs footer.
4. Recovery acquires that same lock read-only, fully validates topology/bytes,
   replays every Event v1 into private `Tay.State.Transition` state, revalidates
   its frozen view, then promotes the same session to mutation. Staging is never
   promoted; no repair, prefix salvage, or automatic truncation exists.
5. ETS indexes are disposable projections. Public `get_job/1` reads them after
   recovery. Public revision contains STORE_ID, job ID, runtime generation, and
   physical revision. IDs are random nonzero 128-bit values.

Event types are inserted, available, started, finished, cancelled, retried.
Insert persists immutable definition: args, worker/queue keys, scheduling,
timeout, attempts, retry policy, ID and time. Later records persist due time,
attempt/cycle, outcome/execution/disposition/diagnostic, cancellation execution
token, and normal/admin retry. Executing state and its token survive recovery;
external effects are at-least-once, and interrupted execution retries without
consuming a logical attempt.

## Terminology, liveness, retention

Retention is the logical policy for what remains observable. Compaction rewrites
that retained state. Reclamation deletes obsolete physical files only after a
new authority is durably published.

A record is live only when required by the canonical representation of a
retained job. It is superseded only after a validated snapshot replaces the
whole required chain. Age alone never makes it dead. Scheduled, available,
executing and retryable jobs are live. Completed, cancelled, and discarded jobs
are terminal and history-retained until policy expiry. Source records become
reclaimable only after their generation is no longer current.

Bootstrap implementation policy (Phase B) is `:infinity`, solely to reduce
variables while snapshot/publication/recovery correctness is proven. It is not
the production default. Production retention is bounded and configurable; its
contract is `terminal_retention: {:hours, positive_integer}` (the user-facing
configuration spelling may later use another bounded duration type). Its exact
built-in duration is intentionally unfrozen pending workload and recovery
qualification; approximately one day is a candidate, not a commitment.

Only `completed`, `cancelled`, and `discarded` may expire. Their accepted
terminal mutation sets durable `terminal_at` to that mutation's `at`; all
nonterminal states have `terminal_at: nil`. V1-to-V2 replay derives it from the
terminal Event-v1 `at`. A snapshot stores `terminal_at` explicitly. The
deadline compares it with one captured compaction clock, never file mtime.
Scheduled, available, executing, retryable, unsettled, and
unknown-outcome/reconciliation-required jobs never expire. On expiry,
`get_job/1` is `:not_found`; retry/cancel are not found. No tombstone is needed
today: IDs are random and Tay has no store merge or import/replay feature. An
old backup may revive an expired job under the existing restore contract. If a
no-reuse or cross-store import promise is added, it needs a separate durable
identity/tombstone design.

## Store v2 proposal

Keep all v1 formats and fixtures unchanged. A v2 root retains immutable STORE
and adds a versioned `CURRENT` pointer and authority-epoch directories. Each
epoch has an immutable compacted base and one designated mutable append tail;
the directory/epoch is therefore not itself immutable after publication.
CURRENT contains version, opaque monotonic generation ID, STORE_ID, and manifest
digest. The manifest contains format version, source generation, source sealed
segment IDs/digests, source frontier last sequence, captured policy/time, and
complete candidate inventory/digests. Recovery chooses exactly CURRENT after
checksum/identity validation, never newest mtime and never a merge of two
generations. A v1 store lacking CURRENT uses existing recovery.

`JOB_SNAPSHOT` is a new explicit format/schema, never a silent Event v1 type.
It encodes job ID, canonical immutable definition bytes, state, attempt and
next-attempt, cycle, execution token, eligible/available/inserted/attempted/
completed times, diagnostic, and durable logical revision/provenance. It must
be bounded, CRC-framed, unique per job, and canonical-order sorted. Snapshot
coordinates are format-local, not v1 sequence numbers.

Before publication, replay the pinned source frontier with existing Event v1,
apply retention, and build expected state. Recover the candidate snapshot and
require exact equality of all retained durable fields/definition bytes after
canonical availability-order renormalization; separately require exact queue
and task-index ordering equivalence. Also
verify physical framing, STORE_ID, inventory checksums, lifecycle validity,
queue/scheduling invariants, ordering, uniqueness, and frontier identity.
Output is deterministic for the same source/frontier/policy time/config;
generation nonce is not semantic.

The Phase-B metadata codec fixes these bytes before publication work. The
`STORE-V2` root marker is exactly 28 bytes: `"TAY2"[4] || version=1[1] ||
reserved=0[3] || STORE_ID[16] || CRC32C[4]`. `CURRENT` is exactly 76 bytes:
`"TAYC"[4] || version=1[1] || reserved=0[3] || STORE_ID[16] ||
epoch_id[16] || SHA256(manifest bytes)[32] || CRC32C[4]`. The manifest is
`"TAYM"[4] || version=1[1] || reserved=0[3] || Value-body-length[4] ||
canonical Value map || CRC32C[4]`. Its exact schema-1 keys are `store_id`,
`epoch_id`, `source_epoch_id` (nil for V1), `source_frontier`, `captured_at`,
`terminal_retention` (`"infinity"` OR canonical Value map `{"hours" => N}`), `source_segments` (ordered ID
and SHA256 digest), `base_segments` (ordered ID, first/last physical sequence,
byte length and SHA256 digest), `tail_segment_id`, and
`tail_first_sequence`. IDs/digests are Value byte strings, not arbitrary text.
The decoder checks CRC, length, exact keys, topology, identity and pointer
digest before this metadata can select authority.

### Approved Phase-C schema-1 retention value amendment

The existing `terminal_retention` field has exactly two canonical Value forms:
`"infinity"` maps to Elixir `:infinity` (the Phase-B bootstrap representation);
the exact one-key map `%{"hours" => N}` maps to `{:hours, N}` (the Phase-C
bounded extension). `N` MUST be an integer in `1..2_562_047_788_015`, derived as
`floor(9_223_372_036_854_775_807 / 3_600_000)` from `Tay.Event.V1.max_time/0`.
Accepted duration multiplication cannot exceed the existing durable timestamp
bound. Expiry uses `captured_at >= duration` AND
`terminal_at <= captured_at - duration`, including equality, rather than adding
duration to terminal time. Only completed/cancelled/discarded may expire after
execution drain/settlement; protected or live states never expire.

Unknown forms, additional/missing map keys, alternate units, strings other than
`"infinity"`, floats, zero, negatives, nil, and maximum+1 fail closed; no fallback
to infinity is permitted. Config and manifest use the shared normative retention
validator. Practical policy/timer bounds, if stricter, must be documented separately.
The manifest records the exact policy and the single captured clock used to
construct retained state; bounded expiry cannot be labelled infinity.

This is an additive value extension of an existing schema-1 key, not a new
authority layout. TAYM framing/version=1, the exact manifest key set, STORE-V2,
CURRENT, CRC32C and manifest SHA256 binding remain unchanged. Existing infinite
bytes/fixtures MUST remain unchanged. Phase-C readers read Phase-B manifests;
pre-Phase-C readers may refuse bounded manifests and MUST NOT repair/migrate
them. New Phase-C literal fixtures are added separately.

## Store v2 mutation and logical revision model (normative)

This section resolves the post-snapshot write path. In Store v2,
`physical_sequence != logical_job_revision`. Every normative `MUST` here is a
Store v2 recovery and mutation requirement, not a change to v1.

### Authority epoch, physical coordinates, and append architecture

`CURRENT` identifies one persisted authority epoch ID. An epoch is a directory
with an immutable, sealed **base** of snapshot segments and a single mutable
**tail** stream in the same epoch-local `segments/` directory. Its immutable
manifest names the sealed base inventory, the first tail segment ID/physical
sequence, and the base's last physical sequence. At publication the Writer
creates and syncs both the sealed base and an empty, header-only active tail
before CURRENT can select the epoch. The tail is the only part normal mutations
may append/rotate; later tail segments have contiguous IDs after the base and
are discovered as a mutable suffix, not listed in the immutable manifest. It
follows current Writer rules: one owner, active highest segment only, staged
successor, file sync, rename, directory sync, identity recheck, and no in-place
rewrite of sealed files. The manifest is never amended for tail appends.

“Immutable generation” means this immutable snapshot base plus manifest, not a
claim that an authoritative epoch has no appendable data. At next stop-the-world
compaction the Writer drains execution, seals the old epoch tail, replays base
and tail, and publishes a new epoch with a newly immutable snapshot base and a
new empty mutable tail. The old complete epoch becomes reclaimable only after
the new CURRENT protocol succeeds. This gives one authoritative state, one
writer, a deterministic frontier, and no lost active tail.

Physical Record-v1 `sequence` remains a 64-bit physical traversal coordinate.
It starts at 1 in each authority epoch, is contiguous over that epoch's base
then tail, and resets to 1 in a newly published epoch. Segment IDs similarly
are epoch-local and contiguous. The pair `{epoch_id, physical_sequence}` is
useful for physical ordering, CRC/topology validation, forensic provenance and
diagnostics, but has no job-lifecycle meaning and is never exposed as a v2 job
revision. Resetting it on compaction is safe because CURRENT chooses exactly one
epoch and provenance contains the epoch ID; recovery never combines streams
from two epochs.

An epoch with retained jobs has one or more sealed base segments containing
snapshots in canonical job-ID order. An epoch retaining zero jobs has no base
data segments and an empty tail beginning at sequence 1; the v2 reader permits
that explicit case even though v1's initialized store cannot be empty.

### Logical revisions and snapshots

Every retained job has `logical_revision :: uint64` in `1..2^64-1`. Insert
creates revision 1. Every accepted semantic transition increments it exactly
once; failed validation does not consume it. The mutation producer refuses an
operation when the current value is `2^64-1` with
`logical_revision_exhausted` before appending bytes. It never wraps, reuses, or
starts a new revision series for the same job ID. This is sufficient for the
bounded v1-style lifecycle and prevents ABA within Tay's supported single-store
history; an exhausted job is operationally unavailable for further mutation,
not silently altered.

Each `JOB_SNAPSHOT` stores the current logical revision as part of canonical job
state. Recovering a snapshot restores that exact value regardless of the
snapshot record's physical coordinate. Compaction is not a job mutation:
logical revision, definition, state, cycle token and execution token are copied
unchanged. Thus a snapshot at revision N followed by a valid mutation produces
N+1, and a later snapshot preserves N+1.

### Record profile and exact mutation strategy

Store v2 retains proven Record v1 framing, header/record CRC32C, length limits,
and segment framing. It defines a distinct Store-v2 semantic profile:

| Record-v1 type/schema | Meaning |
| --- | --- |
| `(7, 1)` | `JOB_SNAPSHOT_V2` |
| `(8, 1)` | `JOB_MUTATION_V2` |

These pairs are physically legal under Record v1 but unsupported Event v1
semantics; only the v2 reader may decode them after validating a v2 root marker
and CURRENT. The v2 root has a separately checksummed Store-v2 marker/version,
and no v1 canonical root `segments/` topology, so an old binary must fail
closed rather than mistake the epoch for v1 history. Future changes use a new
explicit schema or type and fixtures; framing compatibility never implies
semantic compatibility.

Schema `(7,1)` and `(8,1)` use a dedicated bounded V2 payload codec, not an
unversioned reuse of Event v1 maps. Its fixed schema-1 prefix is big-endian:

```
JOB_SNAPSHOT_V2 = job_id[16] || logical_revision[8] || cycle_token[8] ||
                  execution_present[1] || execution_token[8 if present] ||
                  canonical_snapshot_body
JOB_MUTATION_V2 = job_id[16] || mutation_kind[1] || expected_revision[8] ||
                  new_revision[8] || at[8] || canonical_mutation_body
```

All prefix revisions/tokens are unsigned 64-bit fields; zero is invalid except
`expected_revision = 0` on insert. `execution_present` is exactly 0 or 1;
absent execution has no following token. Job IDs are exact nonzero 16-byte
values. Mutation kind is a closed one-byte enum. The remaining body is one
existing bounded canonical `Tay.Event.Value` value consumed exactly to payload
end: an exact string-keyed map whose permitted keys are fixed by snapshot or
mutation kind. Its cycle/execution token values use Value's canonical unsigned
integer tag plus eight-byte payload and MUST be in `1..2^64-1`; they are not
duplicate prefix fields. It contains definitions, timestamps, state fields,
attempts, outcome/disposition/diagnostic and retry fields. This fixes field
order, integer representation, reserved values and exact-consumption rules for
schema 1; literal V2 fixtures are mandatory Phase-B compatibility anchors.
Record-v1 already provides framing CRC coverage, so the V2 codec introduces no
second, inconsistent record checksum.

The exact snapshot body keys are `definition`, `state`, `attempt`,
`next_attempt`, `eligible_at`, `availability_order`, `inserted_at`,
`attempted_at`, `completed_at`, `terminal_at`, and `diagnostic`; absent values
use the existing canonical nil. `state` is a closed V2 enum and all timestamps
retain Event-v1 time bounds. `terminal_at` is present and valid exactly in
completed/cancelled/discarded states. Charge/accounting is recomputed from the
canonical definition, never serialized.

The recommended post-snapshot format is one canonical `JOB_MUTATION_V2` record,
not six independent event framing families. Its bounded canonical payload is:

```
job_id: bytes16
mutation_kind: inserted | available | started | finished | cancelled | retried
expected_logical_revision: uint64       # 0 only for inserted
new_logical_revision: uint64
at: uint64
body: exact kind-specific fields
```

Option A (six `JOB_*_V2` record types) is viable but repeats the same
expected/new-revision envelope and creates six independent top-level schema
evolution points. Option B, this single closed-kind mutation envelope, has one
revision gate and one physical decoder while retaining exact per-kind bodies;
it is therefore the recommended design. A generic state-delta option is
rejected: it would duplicate the transition model, make validation less clear,
and risk accepting states that no lifecycle command could produce.

The body carries the current Event v1 semantic data with physical references
replaced by logical fields: inserted carries the immutable definition,
eligible time and nullable availability order; available carries due time and
availability order; started carries attempt and cycle
token; finished carries outcome/disposition/next attempt/due/diagnostic and
execution token; cancelled carries optional execution token; retried carries
mode, due time and availability order. The existing pure transition rules are
ported once to a v2
logical reducer, with no ETS, clocks, I/O, worker resolution, or atom creation.
This single envelope centralizes revision validation while retaining exact,
bounded per-transition schemas and avoids six duplicate revision envelopes.

The mutation-body map is exact: `inserted` has `definition`, `eligible_at`,
`availability_order`; `available` has `due_at`, `availability_order`;
`started` has `attempt`, `cycle_token`; `finished`
has `outcome`, `disposition`, `execution_token`, `next_attempt`, `next_due_at`,
`diagnostic`; `cancelled` has `execution_token`; and `retried` has `mode`,
`new_due_at`, `availability_order`. No unknown or optional schema-1 key is
accepted. The V2 reducer
enforces the same nilability, attempt range, retry interval, outcome and
diagnostic constraints as Event v1, translated to logical references.

When an inserted, available, or retried mutation enters `:available`, the
reducer requires the body `availability_order` to equal the next global
allocator value; scheduled inserts require nil. Started/cancelled/leaving
availability clears it. The allocator is serialized with all accepted
mutations by the single Engine/Writer path and fails before uint64 overflow.
Recovery derives its next value from snapshot orders and every tail allocation,
including jobs that subsequently left availability. No two accepted entries
receive the same value within an epoch.

`availability_order` is a storage-internal, nonzero uint64 global FIFO
tie-breaker, separate from physical sequence, per-job logical revision,
public revision, and cycle/execution tokens. Current `QueueIndex` sorts
`{queue_key, eligible_at, available_sequence, job_id}`; `TaskIndex` sorts
`{queue_key, worker_key, eligible_at, available_sequence, job_id}`. V2 replaces
only that sequence component with `availability_order` and preserves both
relative orders. At compaction, sort current available jobs by the durable
queue key, assign canonical orders `1..N` in that order, and set the new epoch
allocator to `N+1`. Every nonavailable job stores nil. This internal
renormalization changes no job logical revision or queue/task order and makes
repeated snapshots deterministic. A new availability entry after publication
receives an order greater than all retained available jobs.

`new_logical_revision` is deliberately stored, not merely derived. Replay MUST
verify `new == expected + 1` without overflow. Redundant encoding makes a
corrupt/stale/reordered record locally diagnosable and protects future encoder
mistakes; it does not grant a producer freedom to skip revisions.

### Tokens, insert, and transition application

V2 cycle and execution tokens are logical identities, never physical sequence
numbers. `cycle_token :: uint64` equals the logical revision that began the
current execution cycle: 1 at insert and the new revision of an administrative
(`retried` mode 1) reset. Normal retry/availability does not change it, matching
the current Transition behavior. A `started` mutation MUST carry the current
cycle token and is accepted only when it matches.

`execution_token :: uint64` is the new logical revision of an accepted
`started` mutation. The job enters executing with that token. Finished and
executing-cancelled mutations MUST carry it; normal cancellation carries nil.
Interrupted settlement is an ordinary finished mutation with the existing
interrupted outcome/disposition semantics and the same execution token. Because
logical revision never regresses or wraps, a token cannot be revived by
compaction, physical renumbering, retry, or a later execution of the job.

An inserted mutation has `expected_logical_revision = 0`,
`new_logical_revision = 1`, a previously absent job ID, immutable definition,
and initial eligible/inserted time. It derives available versus scheduled state
exactly as current insert does, initializes cycle token to 1, and has no
execution token. It is the normal durable record for a post-v2 new job; it is
not a snapshot. A snapshot-restored job and an inserted job construct the same
in-memory job map, including immutable definition bytes and all logical fields.

For every noninsert mutation, replay obtains the job by ID and requires:

```
expected_logical_revision == job.logical_revision
new_logical_revision == job.logical_revision + 1
kind-specific v2 transition predicates hold
```

It then applies the transition and sets `job.logical_revision` to new. Missing,
duplicate, stale, reordered, skipped, or overflowed mutations are semantic
corruption and fail closed. Physical order need not equal logical revision
across jobs; it is only a total storage order. It does remain in-order for a
given job because expected-revision validation rejects reordering.

### Public revision handles and compaction behavior

Current v1 public revisions are `{:tay_revision, store_id, job_id,
runtime_generation, physical_revision}`. V2 changes the opaque value to:

```
{:tay_revision_v2, store_id, authority_epoch_id, job_id,
 runtime_generation, logical_revision}
```

`runtime_generation` remains because current admission/lifecycle deliberately
invalidates handles across an Engine restart. `authority_epoch_id` deliberately
invalidates handles issued before a successful compaction even when the job's
logical revision is unchanged. Mutators require all fields to match the current
Engine and job; otherwise they conflict and callers refetch. The handle contains
no physical sequence. This separates durable revision continuity from external
handle validity and ensures a pre-compaction handle cannot address a different
post-compaction logical state.

### Recovery and mutation crash behavior

V2 recovery validates STORE-v2 marker, CURRENT, manifest, base inventory, and
tail topology under the existing lock. It scans all base snapshots in canonical
job-ID order, requires exactly one snapshot per retained ID, validates fields,
logical revisions and token invariants, then scans tail mutations in physical
sequence order. It applies the exact checks above to reconstruct the candidate
map, then rebuilds scheduler/queue/execution projections from that map. It does
not trust ETS, a summary counter, or the manifest as semantic proof. A tail may
contain new inserts as well as mutations of snapshot jobs.

Crash semantics for a v2 tail are the existing append contract: a partial frame,
CRC failure, incomplete tail, rotation failure, changed identity, or uncertain
sync fails closed without salvage; it never makes a writable prefix authoritative.
The first mutation after CURRENT publication writes only to the already-created,
synced empty tail. A crash after physical append but before API reply can leave
the accepted mutation durable; the caller receives/reconciles unknown outcome
by job ID and revision, never retries with a fresh ID. A crash during rotation
uses the existing staged-successor protocol. None of these cases change logical
revision based on physical coordinate.

### Complete lifecycle example

For job J, physical coordinates are written `E:seq`, logical revisions `r`:

| Action | Physical record | Logical result |
| --- | --- | --- |
| insert available | `E1:1` mutation | `r=1`, cycle=1 |
| start attempt 1 | `E1:2` mutation | `r=2`, execution=2 |
| finish failure/retryable | `E1:3` mutation | `r=3`, execution=nil |
| available at due time | `E1:4` mutation | `r=4`, cycle=1 |
| start attempt 2 | `E1:5` mutation | `r=5`, execution=5 |
| finish completed | `E1:6` mutation | `r=6` |
| compact | `E2:1` snapshot | `r=6` unchanged |
| administrative retry | `E2:2` mutation | `r=7`, cycle=7 |
| next start | `E2:3` mutation | `r=8`, execution=8 |
| later compact | `E3:1` snapshot | `r=8` unchanged |

This demonstrates both `snapshot(N) + mutation(N -> N+1)` and that neither
compaction nor physical coordinate reset invalidates a live logical token.

### Required V2 properties

In addition to existing compaction properties, test:

```
replay(v2_history).logical_state == replay(compact(v2_history)).logical_state
logical_revision(compact(job)) == logical_revision(job)
physical_rewrite_does_not_change_logical_revision
stale_mutation_expected_revision_is_rejected
snapshot(N) + mutation(N -> N+1) == original_history_through_revision(N+1)
```

Generate/replay cycles and execution tokens across compaction, normal retry,
administrative retry, cancellation, interrupted execution, terminal expiry and
post-snapshot insertion. Assert tokens cannot be accepted after the represented
cycle/execution is gone, and physical-sequence reset never affects acceptance.
Also generate equal-due available jobs and assert snapshot/recovery preserves
their durable queue order through `availability_order`.

## Frontier, ownership, concurrency

Only sealed source segments are inputs. The active segment is never rewritten.
For Phase B the guardian closes admission and drains/fences execution using
existing semantics; the Writer rotates to seal any nonempty active segment and
captures the full sealed inventory/digests and last sequence under its existing
owner lock. Durable writes remain paused through replay, output, validation and
publication. Thus the frontier is the entire old generation; no tail can be
lost or stale.

All durable work and final validation stay in the existing Writer/native owner.
A supervised helper may calculate read-only liveness from a pinned view but may
not write or publish. The guardian holds one compaction permit; a second call is
`:busy`. This preserves single-writer and flock contracts.

An online alternative would rotate, capture a sealed prefix, write an identified
old-generation tail concurrently, and prove at switch that CURRENT still names
the captured source while splicing the tail exactly once. It adds rotation,
shutdown, admin revision, execution, ABA, and double-publication races. Reject
it for the first implementation.

## Production automatic policy and lifecycle integration

### Product and zero-configuration contract

Compaction is enabled by default. A normal Tay installation must not require an
operator to configure, schedule, monitor, inspect, or manually invoke
compaction in order to prevent unbounded accumulation of **reclaimable**
history. This is not a promise of a fixed disk bound independent of workload:
live jobs, retained terminal history, candidate headroom, a failed disk, and a
disabled policy still consume space. It is a promise that Tay evaluates and
reclaims eligible obsolete history itself under safe conditions.

`Tay.compact/1` remains useful as an administrative override, deterministic
test hook, benchmark tool, explicit maintenance action, and forced request. It
is not the normal production workflow and must use the same safety gate and
single-compaction permit as automatic work.

### Configuration and policy contract

The Engine config gains a validated `compaction:` option with internally loaded
safe defaults when omitted. The intended shape is:

```elixir
compaction: [
  enabled: true,
  terminal_retention: {:hours, ...},
  check_interval: ...,
  min_interval: ...,
  min_sealed_segments: ...,
  min_reclaimable_bytes: ...,
  dead_ratio_threshold: ...
]
```

All durations, byte counts, counts and ratios must be finite, positive where
appropriate, bounded below/above, and reject duplicate/unknown keys. Exact
defaults are not frozen until qualification establishes workload, pause,
recovery, and disk-amplification limits. The stable behavior is enabled by
default, bounded terminal retention, periodic cheap evaluation, threshold-based
rewrite, cooldown, and conservative deferral.

`compaction: false` is supported as an explicit advanced opt-out. It disables
automatic evaluation and triggering; manual forced compaction may remain
available. The configuration documentation must warn that reclaimable durable
history can then grow indefinitely and the operator assumes storage management.

### Evaluation versus compaction

One periodic evaluator performs a cheap policy check; it does not replay the
full store merely to decide. The initial conservative estimator is maintained by
the Writer/Engine from acknowledged event metadata and sealed-segment accounting:
it may under-estimate reclaimable bytes but must never overstate them as safe
space. Expiry candidates can be counted from bounded terminal summaries keyed
by durable terminal time. If the estimate is unavailable after recovery or a
policy/config change, evaluation defers rather than forcing a full rewrite; the
next actual candidate construction remains the authoritative semantic check.

Actual compaction requires a conjunction of qualified policy gates: cooldown
since the last successful publication, sufficient sealed segments, a minimum
conservative reclaimable-byte estimate, an appropriate dead/reclaimable ratio,
and at least one retention-expired terminal job where expiry is the source of
reclaimability. The policy may compact for structural supersession even without
expiry only when a separately qualified estimate and minimum-benefit threshold
say it is worthwhile. It must not rewrite every N minutes merely because the
evaluator ran. A successful generation records enough policy/frontier metadata
to make an already-minimal generation a no-op until new eligible history exists.

Disk pressure is an optional supplemental signal, not an authority to compact.
Free-space APIs and thresholds vary across supported platforms; no portable
signal may bypass candidate-headroom admission. Under pressure with insufficient
headroom, Tay defers/reports the condition and preserves source authority; it
never deletes source data to make space for an unverified candidate.

### Ownership, supervision, races, and shutdown

Recommended ownership is a dedicated `Tay.Engine.CompactionPolicy` child of
the existing per-Engine `Tay.Engine.Supervisor`. The current supervisor already
creates Lifecycle, optional execution runtime, and Engine under `:one_for_all`
with no restart budget; the root Tay supervisor intentionally owns none of
these. Add exactly one policy child to that group. It owns one cancellable timer
and bounded in-memory estimates only; it is neither a writer nor a recovery
authority. This avoids adding timer work to the Lifecycle guardian, whose
existing role is admission, generation, drain/stop/restart coordination.

The policy child asks the Lifecycle guardian for an asynchronous compaction
permit. The guardian serializes it with lifecycle operations and admission,
rejects/defers it while recovering, unhealthy, draining, stopping, busy, or
unable to drain execution, and instructs the existing Writer to perform all
durable operations. There is exactly one logical evaluator and one compaction
permit per Engine. The child schedules the next evaluation only after processing
the current result, preventing mailbox/timer accumulation. It restarts with the
Engine group, discards volatile estimates, and re-establishes them from bounded
recovered summaries.

If another compaction runs, shutdown begins, drain cannot finish, storage becomes
unhealthy, headroom fails, or the store changes before owner acquisition, the
result is a bounded `deferred`/`skipped` reason and a future evaluation. It does
not escalate into unsafe online work or bypass the stop-the-world fence.

### Observability

Emit payload-free, bounded telemetry for `evaluation_performed`,
`evaluation_skipped`, `compaction_eligible`, `compaction_deferred`,
`automatic_compaction_started`, `automatic_compaction_completed`, and
`automatic_compaction_failed`. Reason categories include
`not_enough_reclaimable_bytes`, `ratio_below_threshold`, `cooldown`,
`too_few_segments`, `busy`, `draining`, `insufficient_headroom`, and
`unhealthy`. Include aggregate bytes/counts/durations only; never job args,
definitions, raw job IDs, or unbounded error labels.

## Publication protocol and crash behavior

Extend the native helper with narrow no-follow, identity-pinned operations for
generation directories, immutable files, pointer replacement and unlink. Do
not bypass its lock with `File` calls. In strict Linux `:sync` mode:

1. Create private candidate epoch directory and sync its parent.
2. Create/write/sync/close each canonical snapshot-base segment; seal and sync
   it; create/sync the header-only mutable tail; sync their directories.
3. Write immutable manifest last, sync it and candidate epoch directory;
   validate base and tail through pinned read-only descriptors.
4. Rename candidate to authority-epoch name and sync generations parent.
   Write/sync staged CURRENT, atomically replace CURRENT, then sync root.
5. Re-open and validate CURRENT, its immutable base, and designated active tail
   before replying.

macOS `:write` retains its existing development-only power-loss statement.
Linux remains limited to the validated local filesystem/Btrfs qualification.
Every create, rename and unlink requires parent-directory sync. The point of no
return is a synced, post-read-verified CURRENT. A lost reply then produces an
unknown outcome reconciled by CURRENT/status, never a blind re-publish.

| Failure boundary | Authority after restart | Allowed result |
| --- | --- | --- |
| before/after frontier; output mkdir/write/rotation/seal/sync | old CURRENT | abandoned temp may leak |
| candidate validation or complete candidate before pointer | old CURRENT | candidate ignored or forensic retained |
| pointer replacement | old or new only if complete checked pointer validates | never merge/guess |
| verified switch before reply/reclamation | new CURRENT | unknown prior caller outcome |
| unlink/cleanup at any point | new CURRENT | defer remaining old deletion |

Startup validates STORE, CURRENT, manifest, and exactly named authority epoch.
An
invalid/missing CURRENT in an adopted v2 store is preserve-and-stop. Candidates
are non-authoritative. Old complete epochs are ignored, never merged; cleanup
may remove only a proven non-CURRENT candidate. Disk-full/short-write before
switch leaves old authority untouched; source is never deleted to make space.
Once published, unlink failure is success with `reclamation: :deferred`, not
rollback.

## Sequences, execution, bounds, API

V1 cannot have sparse sequence coordinates. V2 therefore uses the generation-
local physical coordinates and independently monotonic per-job logical revisions
defined above; a snapshot alone cannot safely accept subsequent v1 mutations.
Old opaque revisions after compaction conflict and require refetch; do not
translate them. Phase B drains/settles execution instead of snapshotting
unsettled effects.

Replay is streaming and uses existing bounded candidate accounting; raw history
is never loaded wholesale. Reserve source + worst-case candidate + active tail
+ manifests + headroom (conservatively near 2x source) before starting. Bound
jobs/bytes/nodes, open FDs, directory entries, segments, candidate duration,
pause duration, and startup cleanup. The existing 10,000-job/19.39MB profile is
finite evidence, not a general compaction capacity guarantee.

Manual API: `Tay.compact(name: ..., timeout: ..., terminal_retention: ...)`
returns `{:ok, stats}`, `{:ok, %{changed?: false}}`, `{:error, %Tay.Error{}}`,
or `unknown_outcome`. It is an administrative forced request, not the primary
path. Its requested policy is subject to the same execution-drain, health,
headroom, candidate-validation, and publication gates as automatic compaction;
“forced” never permits unsafe source deletion or a skipped validation. Stats
are payload-free: generations, bytes, segments, live/removed records,
retained/expired terminals, durations, trigger kind, and reclamation state.
Reject busy, shutdown/draining, unhealthy/incomplete recovery, bad policy,
insufficient space, or candidate mismatch. Shutdown before pointer publication
cancels candidate work; after it waits through atomic switch and defers
reclamation.

## Tests, compatibility, phases

Required properties: generated valid histories covering all events, scheduled,
retryable, cancelled, discarded/admin-retried, interrupted, queues and many
frontiers satisfy retained `replay(H) == replay(compact(H))`; fixed-time
idempotence; deterministic/no-op behavior. Fault-inject every listed durable
step, disk-full/short writes, lost reply, shutdown, partial deletion, malformed
manifest/CURRENT/snapshot, and cross-process lock contention. Preserve and run
existing fixtures, recovery adversarial/property tests, VM crash matrix,
large-segment/recovery, 10,000-job and 1GiB tests as applicable; formatting and
warnings-as-errors on macOS and validated Linux/Btrfs strict sync; ASan/UBSan if
the native helper changes. Phase C additionally requires enabled-by-default
configuration tests, strict policy validation, evaluator timer/one-child tests,
cheap-estimate conservatism, threshold/cooldown/no-churn properties, every
defer reason, restart/shutdown behavior, unhealthy/draining/busy races, and
bounded-retention expiry tests for each terminal state.

Frozen v1 Record/Segment/STORE/Event bytes, CRC32C, 1GiB limit, STORE_ID,
single writer, no repair, strict-sync/macOS rules, at-least-once behavior,
single-node scope and lifecycle semantics stay unchanged. Old binaries must
hard-refuse a v2 CURRENT; rollback after v2 publication is unsafe. Cold
backup/restore needs a separately updated whole-generation protocol.

Phase A: pure snapshot/liveness representation, equivalence properties,
deterministic encoding, and retention classification; no authoritative switch.
Phase B: approved v2 generation/snapshot output, validation, atomic CURRENT,
recovery, deferred reclamation, and manual/admin invocation for deterministic
testing and qualification. It may temporarily use infinite retention. Phase B
is not production-complete compaction. Phase C: production automatic policy
evaluator, enabled-by-default bounded retention, safe qualified defaults,
threshold triggers, cooldown, observability, strict config, shutdown/startup
behavior, and deferred retry under unsafe conditions. Only Phase C is
production-complete. Online/non-stop-the-world compaction requires another RFC.

## Approval decisions and risk ranking

* **C1a:** approve Store-v2 authority epochs: checked CURRENT selects one epoch
  with immutable snapshot base plus one mutable append tail; physical sequences
  restart per epoch and are never job revisions. Recommended: approve.
* **C1b:** approve Store-v2 semantic profile using Record-v1 `(7,1)`
  `JOB_SNAPSHOT_V2` and `(8,1)` `JOB_MUTATION_V2`, Store-v2 root marker, and
  v2-only recovery. Recommended: approve; v1-only compaction is unsafe.
* **C1c:** approve uint64 per-job logical revisions (insert=1, one increment
  per semantic mutation, fail-before-wrap), logical-revision-derived cycle and
  execution tokens, and v2 public revision handles including epoch ID.
  Recommended: approve.
* **C2:** stop-the-world or online first. Recommended: stop-the-world.
* **C3a:** bootstrap retention during snapshot/publication correctness work.
  Recommended: `:infinity`.
* **C3b:** production terminal retention. Recommended: bounded and enabled by
  default; exact duration awaits qualification.
* **C4:** old binary on v2. Recommended: hard-refuse.
* **C5:** executing jobs. Recommended: drain/settle before capture.
* **C6:** disk headroom. Recommended: configurable conservative ~2x source.
* **C7:** stale revisions. Recommended: conflict/refetch.
* **C8:** production triggering. Recommended: automatic policy-driven
  compaction enabled by default; manual invocation is an override.
* **C9:** zero configuration. Recommended: built-in safe defaults; ordinary
  users neither configure nor schedule compaction.
* **C10:** automatic-policy owner. Recommended: one dedicated policy child in
  `Tay.Engine.Supervisor`, with Lifecycle guardian permit and Writer execution.
* **C11:** disabling compaction. Recommended: support `compaction: false` as
  an explicit opt-out with documented indefinitely growing reclaimable history.

### Remaining blockers

There is no unresolved alternative design for normal post-snapshot mutation:
the approved design is the C1a authority epoch, C1b V2 record profile, and C1c
logical revision/token model above. The global `availability_order` and
canonical `terminal_at` corrections are approved before format release.
Implementation still requires Phase A/B qualification, including literal V2
fixtures and qualification of the specified V2 payload layout.
Numeric automatic-policy defaults remain intentionally unfrozen qualification
inputs, not storage-correctness blockers.

Critical: invalid v1 subset/renumbering; ambiguous pointer publication. High:
unsettled execution transformation; directory-sync/disk-full mistakes; retention
resurrection via a future import promise. Medium: unbounded resources/eager
reclamation and online frontier/ABA races. Medium: an over-optimistic cheap
estimator causing churn or unsafe operational expectations; it must be
conservative and backed by Phase C qualification. High: treating an authority
epoch as wholly immutable despite post-publication writes; the explicit
immutable-base/mutable-tail split above is mandatory.

Store-v2 implementation is in progress. Frozen Store-v1 source formats and
fixtures are unchanged.
