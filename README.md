# Tay

Tay is an Elixir library under development for embedded durable background jobs,
using a segmented append-only log and reconstructable ETS indexes. The
engine has at-least-once execution semantics and no external database or broker.

**Phases 0–5** provide frozen physical storage/recovery and Event v1 contracts,
durable insertion/reconciliation, private indexes, supervised execution,
scheduling, automatic retries and revision-checked cancellation/manual retry.
Phase 6 adds operational controls, cold restore, package and production-profile
qualification. See the implementation reports and measured release gates before
claiming production readiness; R5 approval and publication remain explicit.
Starting the application starts an empty supervisor; it does not establish storage
readiness or a durability guarantee.

Operational references: [operations](docs/operations.md),
[production limits](docs/production-limits.md), [cold restore](docs/restore.md),
[compatibility](docs/compatibility.md), and [packaging](docs/packaging.md).

## Development

The initial baseline is Elixir 1.20 and Erlang/OTP 29. Verification uses Elixir
1.20.2 and OTP 29; compatibility with other versions has not been established.
There are no third-party runtime dependencies. OTP `:crypto` supplies store IDs
and temporary-name randomness. A C11 compiler is required at build time for the
native filesystem Port; releases must include the built helper in `priv/`.
StreamData is a test-only dependency, locked in `mix.lock`, for codec properties.
ExUnit and the built-in formatter are the
other tooling; Credo and Dialyzer remain deferred.

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Properties run as part of `mix test`, using its reported ExUnit seed. Reproduce
a targeted run with `mix test test/tay/storage --seed 123456`, or run just the
properties with `mix test test/tay/storage/record_property_test.exs --seed 123456`.

`mix run -e 'IO.inspect(Supervisor.which_children(Tay.Supervisor))'` prints `[]`,
reflecting the unchanged empty supervisor.
`Tay.Application` validates configuration and then starts the dedicated
`Tay.Supervisor` module, which provides the standard OTP child specification.

## Configuration

`Tay.Config.new/1` validates options. `Tay.Config.load/0` reads the current `:tay`
application environment. The application validates configuration before startup.
Errors have the shape `{:error, {:invalid_config, key, message}}`.

```elixir
Tay.Config.new(data_dir: "local-development/tay", queues: [default: 10, mailers: 2])
```

Queue names must be unique atoms; limits must be positive integers. An empty
queue list is allowed. The default queues are `[default: 10]`. Unknown and
duplicate options are rejected.

An unset `data_dir` is `nil`. A supplied path must be a nonblank UTF-8 string
without NUL bytes. It is expanded against the working directory when loaded,
without creating files, resolving symlinks, or checking storage permissions.

This repository's `config/config.exs` supplies **provisional development/test
defaults**: `var/tay/dev` and `var/tay/test`. Library consumers do not inherit a
dependency's Mix configuration. There is no production path default in the
configuration module. Production builds fail application startup when `data_dir`
is unset; the embedding application/operator must configure it explicitly.
Development/test application startup may remain storage-free with an unset path.
Every explicit storage session requires a configured path. None of the repository
development/test paths is a production storage contract.

## Worker boundary

```elixir
defmodule ExampleWorker do
  @behaviour Tay.Worker

  @impl true
  def perform(%Tay.Job{args: %{"message" => message}}) do
    IO.puts(message)
    :ok
  end
end
```

`perform/1` can return `:ok`, `{:ok, result}`, or `{:error, reason}`. Arbitrary return
values/reasons are not persisted. Outcomes use fixed bounded diagnostics; successful
results are discarded. Callbacks may repeat after infrastructure interruption:
make external effects idempotent or reconcile them explicitly.

Direct `%Tay.Job{}` construction is non-persistent. `Tay.Job.new/3` and the
`use Tay.Worker` builder validate a separate immutable definition and allocate a
stable ID before submission. Runtime structs, module names and arbitrary terms
are never serialized. Only explicitly configured stable keys map to trusted runtime
worker modules; persisted strings never create atoms or load module names.

## Durable jobs and execution

Example for **development only** (`:write` does not promise power-loss durability):

```elixir
defmodule MailWorker do
  use Tay.Worker, key: "mail.send.v1", queue: :default, max_attempts: 10
  @impl true
  def perform(%Tay.Job{}), do: :ok
end

dir = Path.expand("local-development/tay")
# Explicit administrative operation; refuses already initialized storage.
{:ok, _} = Tay.Storage.initialize(data_dir: dir, durability: :write)

# Normally add Tay.child_spec(options) to your host supervisor instead.
{:ok, engine_supervisor} = Tay.start_link(
  data_dir: dir, durability: :write,
  workers: %{"mail.send.v1" => MailWorker}, queues: [default: 10], start_paused: true
)
{:ok, intent} = MailWorker.new(%{"recipient" => "example.invalid"})
{:ok, job} = Tay.insert(intent)
{:ok, same_job} = Tay.insert(intent) # same ID + definition, no second append
{:ok, current} = Tay.get_job(job.id)
%{state: :ready} = Tay.status()
:ok = Tay.resume_queue(:default)
:ok = Tay.drain(timeout: 30_000) # queued jobs may remain; active tasks must settle/die
:ok = Tay.stop()
Supervisor.stop(engine_supervisor)
```

Do not treat initialization as an idempotent ensure operation. A pre-existing
empty root requires `bootstrap: true`; existing history is never overwritten.
Normal Engine startup is existing-only and never calls initialization. Native
closure/flock release can finish asynchronously: an immediate explicit new
startup may report `ownership_busy`; there is no automatic retry or lock deletion.

Production builds reject `:write`. `:sync` requires Linux, explicit
`validated_filesystem: true`, a genuinely validated supported local filesystem,
and explicit production path configuration. There is no automatic mode downgrade.
`Tay.status().durability` reports the actual mode; a write-mode reply is never
relabeled sync-durable. Production release readiness requires the measured Phase 6
qualification and explicit R5 approval.

Use engine-specific options on `child_spec/start_link`, not in the foundation's
`:tay` application environment. `:name` is a trusted atom (default `Tay.Engine`);
pass the same name to `insert/get_job/status`. Call options accept a finite
`:timeout` in milliseconds. `Tay.insert/2` also accepts the builder's `{:ok, job}`
or `{:error, error}` result. Invalid/incomplete direct structs are rejected.

The authoritative immutable intent is `job.definition`, not editable presentation
fields. Store the original ID/definition to reconcile an unknown outcome.
Different canonical definitions under the same ID produce `:id_conflict`; integer
zero and both floating zero encodings remain distinct. Same-ID reconciliation
precedes new-insertion limits, even after a registry/default/limit change or in a
terminal state. Transport/replay/state budgets still apply independently.

`%Tay.Error{kind: :unknown_outcome, job_id: id, operation: :insert}` after a submitted
timeout/exit means the record may exist. No internal automatic retry occurs. Use a
fresh ready generation's lookup or explicitly resubmit the original intent.
Other kinds distinguish `:invalid`, pre-I/O `:capacity`, and `:unavailable`.
Only an authoritative ready-generation lookup returns `{:error, :not_found}`.
Status is a bounded, explicitly stale-capable snapshot served independently of
Writer; it contains no job args, ETS IDs, Port or storage admission capability.

New-insertion defaults are `max_insert_payload_bytes: 1_048_576`,
`max_insert_args_bytes: 262_144`, `insert_value_depth: 32`,
`insert_value_nodes: 10_000`. The exact domains/cross-budget rules are in the
[approved Event appendix](docs/event-v1-contract-appendix.md#f-resource-limits-versus-insertion-limits).
`:recovery` accepts the unchanged Phase 3 option keyword list. Candidate defaults
are `max_jobs: 100_000`, `max_state_bytes: 268_435_456`, `max_state_nodes: 2_000_000`;
these are operational accounting budgets, not persisted limits or exact RSS.
Startup accounts for up to three charged candidate/index views.

Client defaults: `client_slots: 64`, `client_bytes: 67_108_864`,
`caller_timeout: 5_000`. Each slot has `floor(client_bytes / client_slots)` bytes
of request quota; a definition request is charged its canonical bytes plus 256.
Capacity is reserved before payload-bearing messages. Submitted slots remain
occupied after caller timeout/death until processing finishes or the generation
is revoked. There is no unbounded waiting queue. This bounds the cooperative
protocol, not hostile messages or all allocations/exit reasons inside a shared VM.

All six Event types replay and have approved live producers. Removed worker/queue mappings retain jobs
as blocked state; they never create atoms, load persisted module names, or invoke
workers during replay. Scheduling/claims run only after successful recovery,
activation, private-index construction and interrupted-execution reconciliation.

`Tay.cancel/2` and `Tay.retry/2` use an opaque expected revision (captured once if
omitted), never an automatic refreshed retry after an unknown outcome. Cancellation
fences execution durably before best-effort termination; it cannot undo effects.
Infrastructure interruption reuses the logical attempt with a new physical token;
actual worker failure/timeout consumes the attempt. See the frozen Event contract.

`Tay.pause_queue/2`, `resume_queue/2`, `drain/1`, `stop/1` and `restart/1` are volatile
runtime controls, not new Events. A drain timeout stays draining. Forced stop is
explicit and distinct from a successful drain. Restart uses fresh full recovery,
never surviving ETS or a replayed RPC. Operational history/segment ceilings and
active-outcome reserves preserve capacity without deleting retained jobs.

## Physical record codec

`Tay.Storage.Record.encode/1`, `decode/1`, and `decode/2` implement the approved
24-byte Tay v1 header with 28-byte fixed overhead, big-endian integers, header
and record CRC32C, and a 16 MiB hard payload maximum. Payloads are opaque binary
bytes. All types `1..254` and schemas `1..255` are structurally valid, including
pairs the Event layer does not understand. No event registry is consulted.

`decode/2` accepts only `max_decode_payload_bytes`, an independent resource
budget defaulting to the hard maximum. Success returns exactly one record plus
the untouched remainder. Errors and incomplete results consume no bytes, skip
nothing, and never authorize truncation. A physical cursor is not an applied
replay checkpoint: continuity, Event validation, and projection layers
must still validate every event; unknown semantics must stop recovery without
changing storage.

The CRC32C implementation is a pure, bit-by-bit reference implementation with no
native dependency. [Fixed binary fixtures](test/fixtures/storage/record/v1/README.md)
anchor compatibility independently of encoder/decoder round trips. No payload
serialization or recovery policy is implemented or approved by the Record codec.

## Physical segment storage

`Tay.Storage.Segment` and its bounded parser implement the approved 28-byte STORE,
44-byte header, 64-byte footer, canonical filenames, and segment integrity rules.
`Tay.Storage.Reader` validates all canonical history and cross-segment continuity.
`Tay.Storage.Writer` is an **internal**, explicitly supervised temporary child for
bootstrap, one-record append, sealing, and R0–R7 rotation. The root application
does not start it automatically. It accepts opaque bytes from the separate semantic
validator; physical readiness is not permission to replay jobs.

Only the native Port holds the OS lock and writable file descriptors. An uncertain
operation poisons the session without retry. Incomplete/corrupt canonical bytes
stop startup without repair; recognized header-only staging files are retained.
There is no truncation, stage deletion, segment deletion, or scan-forward recovery.

Strict `:sync` is Linux-only on an operator-validated supported local filesystem;
the default is fail-closed, with no downgrade. macOS provides development `:write`
only when locking and publication capabilities pass, without a power-loss promise.
See the [native protocol and platform assumptions](c_src/README.md),
[permanent segment fixtures](test/fixtures/storage/segment/v1/README.md), and
[Phase 2 implementation/verification report](docs/phase-2-implementation-report.md).
The explicit, slower 1 GiB bounded-parser test is opt-in:

```sh
TAY_LARGE_SEGMENT_TEST=1 mix test test/tay/storage/segment_large_test.exs --warnings-as-errors
```

## Recovery boundary

`Tay.Storage.Recovery.inspect/2` performs physical inspection only.
`replay/5` requires an explicitly configured `EventDecoder` and pure reducer;
it validates the entire physical history before any semantic callback. Unknown
types/schemas, invalid payloads and callback errors stop replay without skipping
events or returning a partial candidate. Every complete contiguous understood
event participates, even if the previous caller acknowledgement is unknown.
No exactly-once guarantee follows.

`Tay.Storage.Writer.start_recovered_link/2` retains its private candidate under
the same Writer → native helper/Port → existing lock session. Its status initially
reports `:awaiting_activation`. `activate_recovered/2` requires that live session
reference, revalidates the store and completes Phase 2 barriers before returning
the candidate and a distinct mutation-admission reference. Recovered append,
seal and rotate calls require that admission reference. Offline inspection
results, old references and release/reacquire handoffs cannot activate a writer.

Recovery inspects **existing initialized storage only**. It never creates a
missing root, lock, STORE or segments directory. Bootstrap remains separate.
An incomplete Record/footer/canonical suffix preserves all evidence, publishes
no partial recovered state, never reuses occupied/ambiguous sequence space and
refuses writable activation. There is no automatic repair or writable restart
from a torn tail, and no journal, watermark or acknowledgement sidecar.

Recovery budgets are operational, not format limits. Budget refusals preserve
storage and can be retried with adequate resources in a fresh attempt. An I/O
timeout after activation begins has the existing uncertain-outcome semantics;
it is not permission to retry a mutation. Callbacks are trusted, bounded and
pure; callback/kernel stalls are not preempted by cooperative deadlines alone.

See the [approved Phase 3 RFC](docs/phase-3-recovery-rfc.md) and
[implementation report](docs/phase-3-implementation-report.md). The opt-in recovery
tests exercise a real 1 GiB store and many small segments:

```sh
TAY_LARGE_RECOVERY_TEST=1 mix test test/tay/storage/recovery_large_test.exs --warnings-as-errors
```

## Architecture and review input

- [Authoritative development plan](TAY_PLAN.md)
- [Implemented Phase 0–6 architecture and scope](docs/architecture.md)
- [Accepted adversarial review input for the future Phase 1 RFC](docs/phase-1-review-input.md)
- [User-supplied record and segment candidates for future RFC review](docs/storage-rfc-input.md)
- [Approved Phase 1 storage format RFC](docs/phase-1-storage-format-rfc.md)
- [Approved Phase 2 segment/rotation RFC](docs/phase-2-segment-format-rotation-rfc.md)
- [Approved Phase 3 recovery RFC](docs/phase-3-recovery-rfc.md)
- [Approved production roadmap](docs/production-roadmap-rfc.md)
- [Approved Event v1 contract and literals](docs/event-v1-contract-appendix.md)
- [Phase 4 implementation report](docs/phase-4-implementation-report.md)
- [Phase 5 implementation report](docs/phase-5-implementation-report.md)
- [Phase 6 qualification report and release gates](docs/phase-6-implementation-report.md)

The accepted review input supplements the plan, including the requirement to
start fixed compatibility fixtures in Phase 1. The supplied record/segment
candidates are preserved as historical design input. The approved Phase 1 RFC
supersedes their record proposal and establishes the v1 physical compatibility
contract. The Phase 2 RFC and its approved implementation gates supersede the
segment candidate. The Phase 3 RFC resolves recovery gates G1–G6 without changing
either byte format. Phase 4 adds Event semantics and disposable projection without
changing those contracts. Phase 5 execution and Phase 6 operational implementation
retain the same contracts; measured R5 approval and publication remain explicit
release gates, not an automatic consequence of a green development build.
