# Implemented architecture: Phases 0–3

[TAY_PLAN.md](../TAY_PLAN.md) is the authoritative project specification. The
approved Phase 0 scope is a reusable Mix library with configuration, application
startup, a runtime job struct, a worker behaviour, documentation, and baseline
tests. Phase 1 adds the pure physical record codec according to the separately
approved [storage format RFC](phase-1-storage-format-rfc.md). Phase 2 implements
physical segmented I/O under the approved
[segment/rotation RFC](phase-2-segment-format-rotation-rfc.md) and the user's
resolved implementation gates. Phase 3 adds the approved non-destructive recovery
and activation boundary, with EventDecoder behaviour and test-only providers.
Production Event semantics, projection and execution remain absent.

## Current modules

| Module | Responsibility |
| --- | --- |
| `Tay` | Documents the available library boundary |
| `Tay.Application` | Validates configuration, then starts an empty named supervisor |
| `Tay.Supervisor` | Implements the empty OTP root supervisor and its child specification |
| `Tay.Config` | Reads runtime application configuration, validates and normalizes it |
| `Tay.Job` | Holds an initial in-memory job description |
| `Tay.Worker` | Defines the `perform/1` behaviour callback |
| `Tay.Storage.Record` | Encodes/decodes one opaque v1 physical frame with exact integrity and limit checks |
| `Tay.Storage.CRC32C` | Internal bit-by-bit Castagnoli reference checksum, with explicit raw incremental state |
| `Tay.Storage.Segment` | Pure STORE/header/footer codecs, physical limits and canonical names |
| `Tay.Storage.Segment.Parser` | Bounded positional scanning, exact framing, segment CRC and sequence checks |
| `Tay.Storage.Reader` | Safe discovery, store identity and complete multi-segment topology validation |
| `Tay.Storage.Native` | Owner-only versioned Port protocol; strict reply matching and uncertainty reporting |
| `Tay.Storage.Writer` | Serialized bootstrap, append, seal and R0–R7 rotation; linked Port supervision and poison state |
| `Tay.Storage.Recovery` | Complete physical preflight, ordered semantic gates, private reduction and same-session revalidation |
| `Tay.Storage.Recovery.EventDecoder` | Explicit trusted semantic capability/consumption behaviour; no production implementation |
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
- The remaining storage, replay, indexing, and execution invariants require
  their corresponding future components and are not proven by codec tests alone.

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
must stop recovery with storage unchanged. No Event encoding, truncation, tail
repair, snapshot, manifest, compaction or deletion is implemented.

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
module fingerprint. No production Event numbers, serialization or raw-byte
fallback are selected. Tests use artificial providers only in `test/support/`.

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

Physical framing/integrity precedes future sequence continuity, then Event
type/schema/payload validation, then projection. Record accepts every assignable
type/nonzero schema but does not authorize semantic replay. Unknown semantics
must stop future recovery without changing storage; `incomplete` never grants
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
