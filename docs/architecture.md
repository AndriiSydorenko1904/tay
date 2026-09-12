# Implemented architecture: Phases 0–4

[TAY_PLAN.md](../TAY_PLAN.md) is the authoritative project specification. The
approved Phase 0 scope is a reusable Mix library with configuration, application
startup, a runtime job struct, a worker behaviour, documentation, and baseline
tests. Phase 1 adds the pure physical record codec according to the separately
approved [storage format RFC](phase-1-storage-format-rfc.md). Phase 2 implements
physical segmented I/O under the approved
[segment/rotation RFC](phase-2-segment-format-rotation-rfc.md) and the user's
resolved implementation gates. Phase 3 adds the approved non-destructive recovery
and activation boundary. Phase 4 implements production Event v1, pure lifecycle
transitions, bounded reconstruction, private indexes and Engine insertion/read
APIs under the approved roadmap/appendix. Execution remains absent.

## Current modules

| Module | Responsibility |
| --- | --- |
| `Tay` | Explicit Engine supervision, insert/get/status APIs |
| `Tay.Application` | Validates configuration, then starts an empty named supervisor |
| `Tay.Supervisor` | Implements the empty OTP root supervisor and its child specification |
| `Tay.Config` | Reads runtime application configuration, validates and normalizes it |
| `Tay.Job`, `Tay.JobID`, `Tay.Error` | Immutable definition builder, stable public IDs, disposable views and bounded errors |
| `Tay.Worker` | Defines `perform/1` and optional explicit-key builder macro; no execution |
| `Tay.Event`, `.Value`, `.V1` | Exact canonical value bytes, six immutable schemas, production EventDecoder |
| `Tay.State.Transition` | Sole pure prepare/apply model and bounded map candidate/accounting |
| `Tay.State.Projection`, `JobIndex`, `QueueIndex`, `SchedulerIndex` | Private unnamed disposable ETS; bounded passive selection |
| `Tay.Engine`, `.Supervisor`, `.Lifecycle`, `.Admission`, `.Config` | Semantic owner, whole-generation revocation, bounded pre-message permits and explicit configuration |
| `Tay.Storage` | Explicit initialize-only administrative operation |
| `Tay.Storage.Record` | Encodes/decodes one opaque v1 physical frame with exact integrity and limit checks |
| `Tay.Storage.CRC32C` | Internal bit-by-bit Castagnoli reference checksum, with explicit raw incremental state |
| `Tay.Storage.Segment` | Pure STORE/header/footer codecs, physical limits and canonical names |
| `Tay.Storage.Segment.Parser` | Bounded positional scanning, exact framing, segment CRC and sequence checks |
| `Tay.Storage.Reader` | Safe discovery, store identity and complete multi-segment topology validation |
| `Tay.Storage.Native` | Owner-only versioned Port protocol; strict reply matching and uncertainty reporting |
| `Tay.Storage.Writer` | Serialized bootstrap, append, seal and R0–R7 rotation; linked Port supervision and poison state |
| `Tay.Storage.Recovery` | Complete physical preflight, ordered semantic gates, private reduction and same-session revalidation |
| `Tay.Storage.Recovery.EventDecoder` | Explicit trusted semantic capability/consumption behaviour; implemented by `Tay.Event` |
| `Tay.Storage.Recovery.Error` | Bounded, payload-free diagnostics; preserve-and-stop action, no repair authority |

`Tay.Supervisor` is a dedicated module using the standard OTP `Supervisor`
behaviour and is registered under its module name. Its current `:one_for_one`
strategy establishes only the Phase 0 root. Restart dependencies for future
state and execution components are not decided here. A caller may explicitly
supervise the internal Writer as a temporary child; it never automatically
restarts an uncertain operation. The native helper exclusively holds flock,
read/directory descriptors, and at most one writable descriptor.

The application reads configuration at startup, validates it, and starts the
supervisor only after validation succeeds. It does not retain mutable state or
apply live configuration changes. `Tay.Config.load/0` independently reads current
application environment values on each call.

## Phase 4 ownership and admission

The explicit host child is an OTP Engine supervisor (`:one_for_all`, zero
automatic restarts). Its guardian starts first; its Engine child is temporary.
Guardian death terminates the runtime group. Engine or Writer failure closes
the gate and leaves only bounded failed-generation diagnostics until the host
stops/restarts the entire group. No Writer is restarted under surviving ETS.

Engine starts the existing recovered Writer with production EventDecoder and a
pure bounded map reducer. Full preflight/replay/revalidation/activation retain
the same Writer, native Port and flock. Terminal coordinate exhaustion grants
no Engine readiness. Private unnamed ETS is allocated only after activation,
loaded and checked before readiness. The full candidate map is then discarded;
only accounting counters survive beside ETS. Codec/reducer replay does not
read time, generate randomness, consult registries, touch ETS or perform I/O.

Only Engine holds the physical mutation admission reference. An insertion is
bounded validation/prepare/accounting → matching Writer receipt → actual sequence
binding → every secondary/index update → reply. Any unexpected receipt or
post-append failure kills the generation, not a rollback. Reads are serialized
by the same Engine. The public revision token is scoped to STORE/job/generation.

The guardian owns a public fixed-size reservation/status ETS table, **not job
projection**. Clients atomically claim free metadata slots and send only a small
reservation RPC. Guardian installs the caller monitor before granting it.
Payloads go to that same guardian, which changes reserved to submitted before
forwarding to Engine. Same-recipient signal ordering makes submit versus caller
DOWN unambiguous. Reserved abandoned slots can be reclaimed; submitted slots
cannot be reclaimed by timeout/DOWN. Only completion or generation destruction
releases them. Tokens prevent ABA/stale-generation forwarding. A bounded reaper
handles abandoned pre-grant claims; it is not a job scheduler timer.

Byte quota is fixed per slot, avoiding a shared-byte-counter crash window.
Definition encoding is bounded/measured on the caller before message admission;
actual new-insertion limits are checked after authoritative same-ID comparison
and before Event output allocation/append. This preserves reconciliation under
lower insertion limits without an unbounded transport exception.

Candidate charge per retained job is twice its canonical definition byte count,
plus 64 times the definition value-node count, plus 2048 metadata bytes. Node
charge is definition nodes + 64. Updates subtract the previous immutable charge;
checks precede map insertion or live append. Up to three charged views are
accounted during startup; this is a deterministic operational envelope, not a
platform-independent peak-RSS assertion. Decoded text/IDs are detached from
backing frames. Secondary indexes never duplicate args. Blocked jobs are counted
and omitted from ready selection without scanning unbounded blocked heads.

All Event schemas/state transitions exist, but the only live event producer is
insertion. Recovered executing state stays inert in Phase 4. No outcome producer,
execution relay, cancellation/retry API, scheduler timer, snapshot, manifest,
retention, batching or repair has been added. Frozen native and physical codecs,
Phase 3 traversal/accumulator semantics and G1–G6 remain unchanged.

## Configuration scope

`data_dir` remains optional in the development/test storage-free foundation. Its unset representation
is `nil`. Configured paths are checked for type, valid UTF-8, nonblank content,
and absence of NUL bytes, then expanded lexically to absolute paths. No directory
is opened or created and no filesystem capability is asserted.

Only the repository's dev/test Mix configuration supplies a provisional path.
Production application startup requires an explicitly configured path. There is
no universal production default. Config records the build environment to enforce
that startup rule without a runtime Mix dependency or an embedded development
path. Every Writer session requires a path and validates actual filesystem
capabilities through the native helper. Strict sync additionally requires an
operator assertion about the actual Linux filesystem/mount/device.

Queues are configuration entries only: ordered, unique atom names with positive
integer limits. `[]` is allowed. No queue processes exist. Invalid and unknown
configuration is reported explicitly, without converting strings into atoms.

## Invariants and phase boundary

- Invariant J: the runtime job struct establishes no durable payload schema.
- Invariant C at the codec boundary: a strict prefix of a valid frame remains
  incomplete, never a different complete record; this does not prove crash durability.
- Invariant I: framing, integrity, unsupported physical interpretation, and
  resource-limit failures retain their distinct classifications.
- Invariants A/C/F/H/I/J at recovery: preserve all evidence, replay complete
  understood events regardless of unknown ACK status, require deterministic
  private reduction, stop on unknown semantics and keep framing registry-free.
- Physical append receipts follow the selected write/sync contract; they are not
  job-insertion receipts. No component dispatches jobs.
- Phase 4 adds insertion/replay/index/generation invariants. Execution and release
  qualification still require Phases 5–6; codec tests alone do not establish them.

The Phase 0 root remains empty, with production path validation added. Phase 1 implements only the approved physical record
format and CRC32C, with no durability mode, segment lifecycle, recovery policy,
payload encoding, state machine, or ID-generation format. The
[user-supplied candidates](storage-rfc-input.md) remain historical input; the
approved RFC supersedes the record candidate. There is no fake in-memory
storage API. No worker callbacks are invoked automatically.

## Phase 2 storage boundary

STORE identity, header/footer checksums, contiguous sequences, canonical ID
topology, and exact physical EOF are checked before opening an active file for
writing. Only the highest segment may be active. A valid highest sealed segment
can publish a new empty header successor, except at ID/sequence exhaustion.
Sealed history is read-only; an incomplete canonical tail blocks startup.

The Port owns offset-explicit operations; BEAM never owns writable storage FDs.
Bootstrap and rotation use exclusive header-only staging, file fsync, atomic
no-replace rename, and parent directory fsync before any append. Acquisition
also syncs the ancestor entry chain to cover interrupted earlier directory
creation. Rotation closes the old writable file before staging the successor,
then closes staging before publication and opening the new canonical writable.
Stages are classified by exact names, type/link count and size, and never deleted.

Only verified full writes advance live sequence/CRC state. Sync receipts require
the append file barrier plus the already completed publication barriers. Any
uncertain write, close, publication, timeout, Port loss or lock/path failure
poisons the session. There is no automatic mutation retry or sequence reuse in
that session. A lost caller response may still refer to a complete durable
record; application idempotency is not solved here.

The native adapter's [documented syscall/platform boundary](../c_src/README.md)
is Linux-only for strict sync, with operator-validated local ext-family/XFS/Btrfs
and capability checks. This run validates Linux on Btrfs; it does not certify
every listed filesystem or simulate hardware power loss. macOS APFS/HFS may
provide development write mode; strict sync and F_FULLFSYNC remain unsupported.

Reader reductions return the final accumulator only after complete physical
validation; reducers must be pure, since callback side effects cannot be rolled
back. Neither reductions nor physical Writer startup grant semantic recovery
readiness. The Phase 3 EventDecoder boundary validates known types, schemas and
payloads before any normal-recovery mutation or projection. Unknown semantics
must stop recovery with storage unchanged. These physical modules do not encode
Events. No truncation, tail repair, snapshot, manifest, compaction or deletion is implemented.

## Phase 3 recovery and activation boundary

The [approved recovery RFC](phase-3-recovery-rfc.md) is normative. Recovery runs
synchronously inside the existing Writer owner, not a second GenServer. The
sequence is existing-only acquisition → full physical preflight → semantic
replay → private candidate → full physical revalidation → mutation activation.
The same native helper and lock remain held throughout; no offline ticket or
reacquisition authorizes mutation. The raw Phase 2 Writer remains physical
tooling, never a fallback for failed semantic recovery.

`Native.open_existing/2` sends opcode 18 and permits only inspection operations.
No mkdir, lock creation, sync, stage, marker, canonical write or successor is
allowed during inspection/replay. After successful revalidation, opcode 19
discharges the deferred existing-ancestor/lock/directory barriers. Highest-sealed
successor publication then follows the unchanged R3–R7 protocol. Terminal
coordinate exhaustion activates read-only, without a successor or admission
reference. Live recovered writes require a newly issued admission reference;
the pre-activation session reference cannot be reused for mutation.

Reader's additive `preflight/2` and `reduce_while/5` use the shared physical parser.
The old physical reductions keep arbitrary-accumulator semantics. The new visitor
must return `{:cont, acc}` or `{:error, reason}`; no successful early prefix is
accepted. Read-file scopes close after callback failures and retain primary
diagnoses when cleanup also fails. Failed close/uncertain helper operation ends
the session. Partial recovered state is never returned or published.

The Event provider must be configured explicitly, including for an empty store.
It declares known types/schemas, decodes the entire payload and reports exact
consumption. It must enforce depth/node/binary budgets while decoding, without
worker loading, atom creation or external effects. The reducer is pure and owns
its candidate-state memory budget. Provider code/configuration and dependencies
must remain fixed for the attempt; the coordinator also checks the provider's
module fingerprint. Phase 3 selected no production semantics; Phase 4 now supplies
the separate approved Event v1 provider. Artificial Phase 3 providers remain only
in `test/support/`; there is no raw-byte production fallback.

Record, footer or canonical incompleteness always preserves bytes and refuses
writable activation. A complete contiguous understood event still participates
despite an unknown prior ACK. These rules do not prove previous caller success,
repair missing bytes or supply exactly-once semantics. Automatic repair needs a
future separately reviewed protocol; Phase 3 adds no persisted recovery state.

Operational defaults are those in RFC §15. Event limits use the map keys `:depth`,
`:output_nodes` and `:binary_bytes`. Limits never change v1 physical validity.
Successor/publication capacity is checked before enabling mutations. Deadlines
are cooperative between operations/events; a hanging trusted callback or stalled
kernel call still requires owner supervision. After promotion starts, timeout is
activation uncertainty, not an untouched resource refusal or retry permission.

## Phase 1 codec boundary

`Record.encode/1` takes a dedicated record struct. `decode/1` uses default
resources; `decode/2` accepts only `max_decode_payload_bytes`. The hard maximum
is 16 MiB regardless of insertion configuration. Neither codec function knows
Event types, runtime job layouts, workers, or application configuration.

Physical framing/integrity precedes sequence continuity, then Event
type/schema/payload validation, then projection. Record accepts every assignable
type/nonzero schema but does not authorize semantic replay. Unknown semantics
must stop recovery without changing storage; `incomplete` never grants
repair authority. Physical cursor advancement is not applied checkpoint progress.

CRC32C uses the approved reflected bit-by-bit algorithm. It retains raw header
CRC state to extend coverage over payload bytes without copying the header and
payload into another combined buffer. Both checksum fields are excluded from
record CRC input. No NIF, native dependency, process, filesystem call, or global
mutable state is introduced by either production codec module.

## Verification and tooling

Use `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
`mix test`. Tests cover configuration rejection and normalization, runtime
configuration loading, startup failure and recovery after correcting
configuration, application shutdown/restart, the worker boundary, and absence of
storage-directory creation. Tests that change application environment or stop
the application run serially and restore the prior environment and application.

Phase 1 tests separately check encoder output and decoder results against all
18 permanent binary fixtures, exact validation precedence and truncation
boundaries, mutations, resource limits, maximum payloads, unknown assignable
numbers, and sequence independence. Seven StreamData properties run in the
ordinary test suite. A test-only normal-polynomial, left-shifting CRC oracle
independently checks generated frames and the 16 MiB boundary.

Phase 2 adds 22 pinned binary artifacts, independent CRC oracles, bounded parsing
properties, native-protocol tests, OS ownership tests across independent BEAMs,
and bootstrap/append/seal/rotation crash and fault tests. The 1 GiB logical stream
test is opt-in; strict Linux tests run only with an explicit validation test root.
The [implementation report](phase-2-implementation-report.md) records exact runs,
platforms, remaining boundaries and the complete changed-file inventory.

The verified toolchain is Elixir 1.20.2 / OTP 29. StreamData is test-only; OTP
crypto and a build-time C11 compiler support the native adapter. Credo and Dialyzer remain deferred. No compatibility
claims for other toolchains are made without verification.

The [accepted review input](phase-1-review-input.md) and
[user-supplied record/segment candidates](storage-rfc-input.md) are retained for
future RFCs. Both physical-format RFCs are now approved and implemented; recording
their design input does not authorize later phases. Phase 3 was separately
authorized against its approved RFC; no Phase 4 implementation is included.

The [Phase 1 storage format RFC](phase-1-storage-format-rfc.md) is the permanent
physical compatibility contract. Later Event/recovery integration tests listed
there remain deferred with their corresponding components; Phase 1 tests do
not claim semantic replay or filesystem safety.
