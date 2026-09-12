# Implemented architecture: Phases 0 and 1

[TAY_PLAN.md](../TAY_PLAN.md) is the authoritative project specification. The
approved Phase 0 scope is a reusable Mix library with configuration, application
startup, a runtime job struct, a worker behaviour, documentation, and baseline
tests. Phase 1 adds the pure physical record codec according to the separately
approved [storage format RFC](phase-1-storage-format-rfc.md). Neither phase
implements persistent I/O, recovery, or execution.

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

`Tay.Supervisor` is a dedicated module using the standard OTP `Supervisor`
behaviour and is registered under its module name. Its current `:one_for_one`
strategy establishes only the Phase 0 root. Restart dependencies for future
storage, state, and execution components are not decided here.

The application reads configuration at startup, validates it, and starts the
supervisor only after validation succeeds. It does not retain mutable state or
apply live configuration changes. `Tay.Config.load/0` independently reads current
application environment values on each call.

## Configuration scope

`data_dir` is optional in the storage-free foundation. Its unset representation
is `nil`. Configured paths are checked for type, valid UTF-8, nonblank content,
and absence of NUL bytes, then expanded lexically to absolute paths. No directory
is opened or created and no filesystem capability is asserted.

Only the repository's dev/test Mix configuration supplies a provisional path.
Production path selection, path requirements, and storage-location guarantees
remain undecided until before Phase 2. The runtime library does not use `Mix` to
choose a directory or embed a development path at compilation.

Queues are configuration entries only: ordered, unique atom names with positive
integer limits. `[]` is allowed. No queue processes exist. Invalid and unknown
configuration is reported explicitly, without converting strings into atoms.

## Invariants and phase boundary

- Invariant J: the runtime job struct establishes no durable payload schema.
- Invariant C at the codec boundary: a strict prefix of a valid frame remains
  incomplete, never a different complete record; this does not prove crash durability.
- Invariant I: framing, integrity, unsupported physical interpretation, and
  resource-limit failures retain their distinct classifications.
- Invariants A and D: no API acknowledges persistence or dispatches a job.
- The remaining storage, replay, indexing, and execution invariants require
  their corresponding future components and are not proven by codec tests.

Phase 0 remains unchanged. Phase 1 implements only the approved physical record
format and CRC32C, with no durability mode, segment lifecycle, recovery policy,
payload encoding, state machine, or ID-generation format. The
[user-supplied candidates](storage-rfc-input.md) remain historical input; the
approved RFC supersedes the record candidate. There is no fake in-memory
storage API. No callbacks are invoked automatically.

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

The verified toolchain is Elixir 1.20.2 / OTP 29. StreamData is test-only; no
runtime dependency is added. Credo and Dialyzer remain deferred. No compatibility
claims for other toolchains are made without verification.

The [accepted review input](phase-1-review-input.md) and
[user-supplied record/segment candidates](storage-rfc-input.md) are retained for
future RFCs. The record RFC is now approved, but recording the segment inputs
does not start Phase 2.

The [Phase 1 storage format RFC](phase-1-storage-format-rfc.md) is the permanent
physical compatibility contract. Later Event/recovery integration tests listed
there remain deferred with their corresponding components; Phase 1 tests do
not claim semantic replay or filesystem safety.
