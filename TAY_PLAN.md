# Tay — Authoritative Step-by-Step Development Plan

> Approved roadmap reconciliation: [production-roadmap-rfc.md](docs/production-roadmap-rfc.md)
> replaces the original granular Phase 4–10 implementation sequence below with
> Phase 4 Durable Job Core → Phase 5 Complete Execution Lifecycle → Phase 6
> Production Qualification and Operations. R1–R4 and the exact
> [Event v1 appendix](docs/event-v1-contract-appendix.md) are approved; R5 remains
> the measured production-release gate. Original Phase 11/12 work stays deferred.
> This numbering reconciliation does not change frozen Phase 1–3 byte/durability
> contracts or G1–G6. The old granular sections are retained as historical input,
> not permission to implement a second event model, repair, snapshots or compaction.

> This document is the authoritative architecture, implementation roadmap, engineering contract, and Codex working specification for **Tay**.
>
> Tay is an open-source durable background job processing engine for Elixir.
>
> Tay is inspired by systems such as Oban, but it must **not** depend on PostgreSQL, Redis, RabbitMQ, Kafka, or any external database/broker.
>
> Treat this project as production infrastructure, not as a tutorial exercise.

---

# 1. Product definition

Tay is an embedded durable job engine for Elixir.

The core idea is:

- durable jobs are persisted into an append-only segmented binary log;
- runtime indexes/state are reconstructed into ETS;
- crashes and application restarts must not lose acknowledged jobs;
- execution semantics are at-least-once;
- the first version is single-node;
- the architecture must allow future extension toward workflows, batches, chains, signals, distributed execution, and other orchestration features.

A concise mental model:

```text
durable log
    ↓
recovery / replay
    ↓
ETS runtime state
    ↓
queue scheduling
    ↓
supervised execution
```

Another useful way to think about Tay:

```text
record → record → record → record → ...
```

The log is history.
ETS is the current projection of that history.
Workers are execution.
Recovery recreates current state from durable history.

---

# 2. Main goals

Implement Tay as a reusable Elixir Mix library.

Primary requirements:

1. Durable persistence without an external database.
2. Crash recovery.
3. Efficient job lookup and queue operations using ETS.
4. At-least-once execution semantics.
5. Multiple named queues.
6. Configurable queue concurrency.
7. Job scheduling.
8. Retry support with backoff.
9. Job cancellation.
10. Job uniqueness support later without requiring a storage redesign.
11. Segmented append-only storage.
12. Snapshotting/checkpointing later without requiring a storage redesign.
13. Safe segment rotation.
14. Safe recovery from partially written records.
15. Clear separation between:
   - persistence;
   - reconstructed runtime state;
   - scheduling;
   - execution;
   - public API.

Correctness is more important than raw throughput during the first implementation stages.

---

# 3. Non-goals for the first version

Do **NOT** initially implement:

- multi-node clustering;
- Raft;
- leader election;
- distributed locks;
- web dashboard;
- batches;
- workflows;
- chains;
- cron;
- plugins;
- metrics exporters;
- advanced orchestration features.

However, do not make architectural decisions that would make these unnecessarily difficult later.

The first implementation should establish a trustworthy durable core.

---

# 4. Public API direction

The public API should feel natural to an Elixir developer.

Example worker:

```elixir
defmodule MyWorker do
  use Tay.Worker,
    queue: :default,
    max_attempts: 10

  @impl Tay.Worker
  def perform(%Tay.Job{args: args}) do
    # work
    :ok
  end
end
```

Job creation:

```elixir
%{"user_id" => 123}
|> MyWorker.new()
|> Tay.insert()
```

Potential public API:

```elixir
Tay.insert(job)
Tay.cancel(job_id)
Tay.retry(job_id)
Tay.get_job(job_id)
```

The exact public API may evolve.

A hard rule:

> Storage internals must never leak into normal application code.

Users should reason in terms of jobs, workers, queues, retries, schedules, and workflows — not segments, offsets, checksums, or log records.

---

# 5. Top-level architecture

Use approximately the following module boundaries:

```text
Tay
├── Application
├── Config
├── Job
├── Worker
│
├── Storage
│   ├── Writer
│   ├── Reader
│   ├── Record
│   ├── Segment
│   ├── Manifest
│   ├── Snapshot
│   └── Recovery
│
├── State
│   ├── JobIndex
│   ├── QueueIndex
│   └── SchedulerIndex
│
├── Execution
│   ├── Queue
│   ├── Producer
│   ├── Executor
│   ├── Retry
│   └── Scheduler
│
└── Application
```

This structure may be refined where there is a strong technical reason.

Do not create abstraction layers merely for architectural aesthetics.

Each module should have one clear responsibility.

---

# 6. Storage architecture

The durable source of truth is a segmented append-only log.

Conceptually:

```text
storage/
├── manifest
├── segments/
│   ├── 0000000000000001.tay
│   ├── 0000000000000002.tay
│   └── ...
└── snapshots/
```

Never use `/tmp` as the default persistent storage directory.

The default data directory must be configurable.

Storage must survive:

- normal process restart;
- BEAM restart;
- application restart;
- machine restart;
- process crashes;
- incomplete final writes.

The storage engine must explicitly define what it can and cannot guarantee across OS crashes and power loss.

---

# 7. Log model

Every durable state transition is represented by a log record.

Potential record types include:

```text
job_inserted
job_started
job_completed
job_failed
job_cancelled
job_retry_scheduled
```

Future record types may include:

```text
job_scheduled
job_discarded
job_unique_lock_acquired
batch_created
batch_member_added
workflow_started
signal_received
```

Do not persist complete mutable database-style rows on every state transition unless there is a justified reason.

Prefer an event/log-oriented model from which current state can be reconstructed.

The format must be versioned from the beginning.

The storage engine must not depend on current runtime struct layout remaining unchanged forever.

---

# 8. Record framing

Design an explicit binary framing format.

At minimum, every record needs enough metadata to support:

- format identification;
- format version;
- record type;
- payload length;
- corruption detection;
- safe detection of incomplete tail writes.

A conceptual frame may look like:

```text
+----------+
| magic    |
+----------+
| version  |
+----------+
| type     |
+----------+
| length   |
+----------+
| payload  |
+----------+
| checksum |
+----------+
```

Do **not** blindly use this exact format without evaluating:

- field sizes;
- endian representation;
- maximum record size;
- payload size limits;
- record type representation;
- checksum choice;
- checksum coverage;
- recovery behavior;
- forward compatibility;
- unsupported version behavior.

The final binary format must be documented byte by byte.

For example, a final specification might eventually say something like:

```text
Offset   Size   Field
0        4      Magic
4        1      Format version
5        1      Record type
6        4      Payload length, big-endian
10       N      Payload
10+N     4      Checksum
```

That is only an illustration.

The real format must be reviewed before implementation.

---

# 9. Serialization

Choose a serialization format for record payloads deliberately.

Requirements:

- deterministic enough for recovery;
- versionable;
- safe to decode;
- reasonable performance;
- no arbitrary code execution during decoding.

Do not use unsafe Erlang term decoding.

If Erlang External Term Format is used, use safe decoding and document compatibility implications.

Possible choices to evaluate include:

- Erlang External Term Format with safe decoding;
- MessagePack;
- CBOR;
- a custom versioned binary representation;
- another deliberately selected format.

Storage framing and payload serialization are separate concerns.

Do not mix record boundary detection with payload decoding.

---

# 10. Durability contract

Clearly define what `Tay.insert/1` means.

If Tay reports insertion success to the caller, the job must have reached the durability level promised by the configured policy.

Support a durability policy that can evolve toward options such as:

```text
:none
:flush
:sync
```

Possible semantics:

### `:none`

The write may only have reached application/OS buffering.

Fastest, weakest guarantee.

### `:flush`

The application has flushed its own buffers, but the data may still only exist in OS cache.

### `:sync`

The implementation performs the strongest supported sync semantics required by the documented contract.

Do not pretend buffered writes are equivalent to durable fsync.

The implementation and documentation must be explicit about these semantics.

If platform/filesystem behavior differs, document the assumptions.

---

# 11. Segment lifecycle

Segments are append-only.

A segment is rotated when a configurable threshold is reached, initially by size.

Example:

```text
segment 1 -> sealed
segment 2 -> active
```

Only the active segment may be appended to.

Sealed segments must not be modified during normal operation.

Design segment IDs so lexical and numerical ordering are deterministic.

For example:

```text
0000000000000001.tay
0000000000000002.tay
0000000000000003.tay
```

The storage engine should be able to detect:

- duplicate segment IDs;
- missing required segments;
- unexpected ordering;
- malformed filenames;
- multiple apparent active segments.

---

# 12. Crash recovery

Recovery is a core feature, not an afterthought.

The general startup roadmap below spans recovery and later projection/snapshot
phases. It does not authorize Phase 3 repair or later-phase implementation. The
approved [Phase 3 recovery RFC](docs/phase-3-recovery-rfc.md) defines the binding
Phase 3 scope and fail-closed tail policy.

On startup:

1. discover valid segments;
2. validate ordering and metadata;
3. locate the latest usable snapshot if snapshots exist;
4. reconstruct state by replaying required records;
5. inspect the active segment;
6. detect incomplete/corrupt tail data safely;
7. preserve incomplete tails and refuse writable activation in Phase 3; any future automatic repair requires a separately reviewed recovery/repair protocol;
8. rebuild ETS indexes;
9. resume processing.

Recovery must distinguish:

- valid record;
- incomplete final header;
- incomplete final payload;
- incomplete final checksum;
- checksum failure;
- invalid magic;
- unsupported version;
- invalid type;
- impossible length;
- corruption in the middle of an existing segment.

Do **NOT** silently ignore arbitrary corruption.

Phase 3 never truncates, pads, deletes, renames aside or repairs an incomplete
Record, footer or canonical suffix. It preserves all bytes, publishes no partial
recovered state, never reuses occupied/ambiguous sequence space and refuses
writable activation. Automatic torn-tail repair and automatic writable restart
from such a tail are not Phase 3 guarantees. No acknowledgement metadata,
repair journals, watermarks or format changes are introduced for this phase.

Middle-of-log corruption should cause an explicit recovery error unless a future recovery policy says otherwise.

A key safety principle:

> An incomplete parse result alone never authorizes discarding data. Any future automatic repair requires independent, explicitly approved repair authorization.

---

# 13. Runtime state

Use ETS for hot runtime indexes.

The log is the durable source of truth.

ETS is disposable and must be reconstructable entirely from durable storage.

Potential indexes:

```text
job_id -> current job state
queue_name -> runnable job IDs
scheduled_at -> job IDs
```

Other future indexes may include:

```text
unique_key -> job_id
worker -> jobs
state -> jobs
batch_id -> members
workflow_id -> nodes
```

Select ETS table types and key structures based on access patterns.

Avoid one giant catch-all ETS table without justification.

Possible ETS table types to evaluate:

- `:set`;
- `:ordered_set`;
- `:bag`.

Do not optimize prematurely, but make indexing choices explicit.

---

# 14. Job model

A job should eventually contain fields conceptually similar to:

```elixir
%Tay.Job{
  id: ...,
  worker: ...,
  queue: ...,
  args: ...,
  state: ...,
  attempt: ...,
  max_attempts: ...,
  inserted_at: ...,
  scheduled_at: ...,
  attempted_at: ...,
  completed_at: ...,
  errors: ...
}
```

IDs must be unique and sortable if practical.

Do not depend on a database sequence.

Evaluate:

- UUIDv7;
- ULID;
- another suitable time-sortable identifier.

Document the decision.

IDs should work correctly across process restarts and future multi-node scenarios.

---

# 15. Job states

Define an explicit state machine.

Likely states include:

```text
scheduled
available
executing
retryable
completed
cancelled
discarded
```

Possible transition examples:

```text
scheduled -> available
available -> executing
executing -> completed
executing -> retryable
retryable -> available
executing -> discarded
available -> cancelled
scheduled -> cancelled
retryable -> cancelled
```

Transitions must be validated.

Do not allow arbitrary state mutations.

The log should reflect state transitions sufficiently to reconstruct current state.

Invalid transitions should fail clearly.

---

# 16. Execution semantics

Tay provides **at-least-once execution**.

Exactly-once execution must **NOT** be claimed.

A worker may execute more than once after crashes around execution acknowledgement boundaries.

Example failure window:

```text
worker performs external side effect
        ↓
process crashes
        ↓
job completion was not durably recorded
        ↓
recovery sees job as unfinished
        ↓
job runs again
```

This is expected under at-least-once semantics.

Workers should therefore be encouraged to be idempotent.

Documentation should explain when application-level idempotency keys or transactional patterns are needed.

---

# 17. Queue execution

Each configured queue has a concurrency limit.

Example configuration:

```elixir
config :tay,
  queues: [
    default: 10,
    mailers: 5
  ]
```

Execution architecture should rely on OTP primitives.

Use supervisors and processes intentionally.

Do not build manual process-management logic where standard OTP behaviour is appropriate.

A queue process should not itself perform arbitrary user work if that would block scheduling/dispatch responsibilities.

Worker execution should happen in supervised child processes/tasks with clearly defined failure semantics.

Do not serialize all user worker execution through one GenServer.

---

# 18. Failure behavior

Worker crashes must not crash Tay globally.

Job execution failure must be classified separately from internal Tay infrastructure failure.

Tay must record enough information to retry jobs appropriately.

Consider worker outcomes such as:

```elixir
:ok
{:ok, result}
{:error, reason}
raise
exit
timeout
```

Define the worker contract clearly.

Do not swallow worker crashes.

Useful error information may include:

```text
attempt number
exception class
message
stacktrace summary
timestamp
duration
```

Avoid persisting unbounded error payloads.

---

# 19. Retries

Failed jobs may be retried until `max_attempts`.

Retry scheduling should support exponential backoff with optional jitter.

For example, an implementation might conceptually use:

```text
base_delay * 2^(attempt - 1)
```

with a cap and jitter.

The exact formula should be configurable or replaceable later.

Keep retry policy separate enough that it can later become configurable.

Persist retry scheduling before treating the failed attempt as fully handled.

A crash must not cause a failed job to disappear between "failure observed" and "retry scheduled".

---

# 20. Supervision

Use an OTP supervision tree.

Conceptually:

```text
Tay.Application
└── Tay.Supervisor
    ├── Storage
    ├── State
    ├── Scheduler
    └── QueueSupervisor
         ├── default
         ├── mailers
         └── ...
```

The exact tree should follow lifecycle dependencies.

Storage/recovery must become ready before queues begin dispatching recovered jobs.

Do not introduce race conditions during startup.

Startup order matters.

One possible lifecycle:

```text
start storage
    ↓
recover log
    ↓
build ETS
    ↓
start scheduler/queues
    ↓
dispatch jobs
```

---

# 21. Writer ownership

There must be one clearly defined owner of mutations to the active log segment.

Avoid uncontrolled concurrent writes from arbitrary processes.

A dedicated storage writer process is acceptable.

For example:

```text
Tay.Storage.Writer
```

may serialize active segment mutations.

If batching is introduced later, it must not break durability semantics.

The writer must define behavior for:

- append success;
- append failure;
- fsync failure;
- segment rotation;
- disk-full;
- restart;
- internal crash.

---

# 22. Backpressure

Do not assume consumers are infinitely fast.

Design interfaces so backpressure can be introduced naturally.

Do not load millions of jobs into process mailboxes.

ETS may contain indexes, but scheduling and dispatch should fetch bounded amounts of work.

Possible patterns to consider later:

- bounded demand;
- queue watermarks;
- pull-based producers;
- scheduled refill;
- executor availability signalling.

Do not prematurely introduce GenStage/Broadway unless there is a demonstrated need.

---

# 23. Snapshots

Snapshots are not required for the first implementation milestone.

However, log replay must be designed so future snapshots can represent:

```text
state at log position X
```

Recovery could then:

```text
load snapshot
+
replay records after X
```

A snapshot must have a defined relationship to the log position it covers.

A snapshot must never permit deletion of log segments unless the system can prove the snapshot is durable and sufficient for recovery.

Snapshots themselves need:

- versioning;
- integrity validation;
- safe write/replace behavior;
- durable completion semantics.

---

# 24. Manifest

Introduce a manifest only when it has a concrete responsibility.

Potential responsibilities:

- storage format version;
- current active segment;
- latest durable snapshot;
- segment metadata.

Manifest updates must be atomic.

Use a safe write pattern such as:

```text
write temp
fsync temp
rename
fsync directory
```

where required by the durability contract and supported platform semantics.

Do not rely on naïve in-place manifest rewrites.

The manifest must not become a single fragile source of truth when its data can safely be reconstructed from segments.

---

# 25. Filesystem assumptions

Be explicit about filesystem assumptions.

Consider:

- partial writes;
- short writes;
- process crashes;
- BEAM crashes;
- OS crashes;
- power loss;
- fsync;
- fdatasync equivalents;
- atomic rename;
- directory fsync;
- disk-full conditions;
- permission errors;
- corrupt files;
- missing files;
- stale temporary files.

Do not treat `File.write/3` success as proof of crash durability.

Where Elixir's high-level APIs hide required semantics, use lower-level Erlang/OTP file APIs deliberately.

Platform-specific behavior must be documented when relevant.

---

# 26. Testing strategy

Storage and recovery tests are mandatory.

## Normal storage

Test at least:

- append one record;
- append many records;
- read records back;
- preserve ordering;
- segment rotation;
- reopen existing storage;
- append after reopen;
- multiple rotations.

## Recovery

Test at least:

- clean shutdown;
- restart without snapshot;
- truncated header;
- truncated payload;
- truncated checksum;
- random bytes appended at tail;
- corrupted checksum;
- invalid magic;
- unsupported version;
- invalid record type;
- impossible length;
- missing segment;
- duplicate segment;
- segments in unexpected order;
- corruption in sealed segment;
- corruption in active segment middle;
- incomplete final record.

## Jobs

Test:

- insert;
- execute;
- complete;
- failure;
- retry;
- exhausted attempts;
- cancellation;
- scheduled execution;
- recovery of available job;
- recovery of retryable job;
- recovery of scheduled job.

## OTP failures

Test:

- worker raises;
- worker exits;
- worker throws if relevant;
- executor crashes;
- queue process crashes;
- writer crashes;
- scheduler crashes.

Use deterministic tests where possible.

Avoid arbitrary `Process.sleep/1` in tests if synchronization can be explicit.

---

# 27. Property-based testing

Use property-based testing where it provides strong value, especially around:

- encoding/decoding records;
- replay;
- truncation boundaries;
- sequences of job transitions.

Consider StreamData.

Important properties include:

### Codec round-trip

```text
record
  ↓
encode
  ↓
decode
  ↓
same logical record
```

### Recovery determinism

Given an arbitrary valid sequence of persisted state transitions:

```text
encode
-> persist
-> recover
```

must reconstruct the same logical state.

### Tail truncation

For any valid encoded record, truncating it at any byte boundary must never decode as another valid record.

### State machine

Random valid transition sequences should never produce impossible job states.

---

# 28. Code quality

Requirements:

- idiomatic Elixir;
- OTP conventions;
- Dialyzer-friendly design where practical;
- clear typespecs on important public/internal boundaries;
- documentation for non-obvious storage invariants;
- formatter clean;
- Credo-friendly style;
- small focused modules;
- no needless macros;
- no unnecessary metaprogramming.

Use `@moduledoc false` only for genuinely internal modules where public module documentation adds no value.

Use `@spec` where it improves contracts and tooling, especially storage boundaries and public APIs.

Do not add typespecs mechanically to every tiny private helper.

Prefer simple explicit code over clever code.

---

# 29. Dependencies

Keep dependencies minimal.

Every dependency must have a justified purpose.

Prefer standard library/OTP functionality where appropriate.

Do not introduce a dependency merely to avoid implementing a small well-understood component.

Potential development dependencies such as StreamData are acceptable.

Any runtime dependency must be reviewed for:

- maintenance quality;
- license;
- transitive dependencies;
- serialization compatibility;
- long-term stability.

---

# 30. Performance principles

Correctness comes before optimization.

However, avoid architectural choices that obviously prevent good performance.

Important constraints:

- sequential writes should remain sequential;
- avoid rewriting entire job state files;
- avoid full-log scans during ordinary runtime operations;
- avoid O(n) queue lookup for each dispatch;
- avoid serializing all worker execution through one GenServer;
- avoid putting large payloads in process state unnecessarily;
- use ETS for indexed hot paths;
- keep recovery streaming where possible rather than loading the entire log into memory.

Benchmarking will be added after correctness is established.

Future benchmarks should eventually cover:

- inserts/sec;
- fsync cost;
- recovery speed;
- queue dispatch throughput;
- retry scheduling;
- memory/job;
- ETS index size;
- segment rotation overhead.

---

# 31. Observability

Internal architecture should make telemetry possible later.

Do not add a large metrics system now.

Useful future events include:

```text
job inserted
job started
job completed
job failed
job retried
queue latency
execution duration
storage append duration
storage sync duration
segment rotated
recovery started
recovery completed
recovery duration
```

Prefer emitting structured internal telemetry events later rather than coupling Tay to a specific metrics backend.

---

# 32. Security and safety

Never dynamically create atoms from arbitrary persisted/user-controlled strings.

Do not deserialize arbitrary executable terms.

Validate persisted metadata.

Treat corrupt storage as an explicit error condition.

Worker module resolution must not allow arbitrary untrusted module execution.

Payload limits must exist to prevent accidental or malicious oversized records.

Do not log secrets unnecessarily.

Persisted arguments may contain sensitive data; future documentation should clearly state storage implications.

---

# 33. Compatibility

The storage format must carry an explicit version from version 1.

Do not assume internal Elixir structs can simply be persisted forever unchanged.

Separate persisted representation from runtime representation when appropriate.

Future Tay versions must be able to recognize an unsupported storage version and fail clearly rather than misinterpreting bytes.

Compatibility strategy should eventually distinguish:

- log framing version;
- payload schema version;
- snapshot version;
- manifest version.

Migration tooling may be added later, but format identification must exist from the beginning.

---

# 34. Non-negotiable invariants

These invariants are architectural contracts.

## Invariant A — acknowledged durability

If `Tay.insert/1` returns success under durable mode, the acknowledged job must survive an application restart according to the documented durability policy.

## Invariant B — ETS is disposable

ETS may always be destroyed and reconstructed from durable data.

## Invariant C — torn append safety

A crash during append must never turn a partially written final record into a valid different record.

## Invariant D — durable existence

Tay must never execute a job that does not exist in reconstructed durable state.

## Invariant E — worker isolation

A user worker crash must not corrupt the storage engine.

## Invariant F — deterministic replay

Replay of the same valid log must deterministically reconstruct the same logical state.

## Invariant G — indexed runtime

Normal runtime must not require scanning the entire historical log to find runnable jobs.

## Invariant H — at-least-once

At-least-once semantics must be preserved across crash boundaries.

## Invariant I — corruption is explicit

Storage corruption must not be silently converted into apparent success.

## Invariant J — persisted/runtime separation

Persisted format compatibility must not depend on the current in-memory struct layout.

---

# 35. Implementation roadmap

Do **NOT** implement the entire system in one giant patch.

Work incrementally.

Before each phase:

1. inspect the existing repository;
2. explain the relevant architectural decision;
3. state the invariants;
4. identify files/modules to add or change;
5. implement;
6. run formatter;
7. run tests;
8. report exactly what passed;
9. stop at the phase boundary unless instructed to continue.

Never claim tests passed without running them.

Never silently weaken tests to make the implementation pass.

Do not modify unrelated code.

---

# Phase 0 — Project foundation

Create/verify:

```text
Tay.Application
Tay.Config
Tay.Job
Tay.Worker
```

Tasks:

1. Initialize a reusable Elixir Mix project/library.
2. Define application startup.
3. Establish configuration loading.
4. Define initial `%Tay.Job{}` runtime struct.
5. Define `Tay.Worker` behaviour.
6. Add ExUnit baseline.
7. Configure formatter.
8. Decide whether Credo and Dialyzer belong in the initial toolchain.
9. Add a minimal README explaining the project direction.
10. Add architecture documentation links.

Do not implement fake in-memory storage to simulate success.

Do not create APIs whose semantics cannot later be made durable.

### Phase 0 exit criteria

- project compiles;
- formatter passes;
- tests pass;
- application starts;
- public boundaries are understandable;
- no fake durability exists.

---

# Phase 1 — Binary record codec

Implement:

```text
Tay.Storage.Record
```

Responsibilities:

- framing;
- encode;
- decode;
- validation;
- checksum;
- format versioning;
- maximum record size enforcement;
- classification of incomplete vs corrupt data.

Before implementation, Codex must propose the binary format byte by byte.

The proposal must explicitly answer:

1. What is the magic value?
2. How many bytes is it?
3. How many bytes is version?
4. How is record type encoded?
5. How many bytes is payload length?
6. What endian order is used?
7. What is the maximum payload size?
8. Where is checksum stored?
9. What bytes are included in checksum?
10. Which checksum algorithm is used?
11. How are unknown versions handled?
12. How are unknown record types handled?
13. How is incomplete data distinguished from corruption?

No GenServer is needed here.

This phase should be as pure and deterministic as practical.

### Required Phase 1 tests

At minimum:

- valid record round-trip;
- empty payload if allowed;
- minimum payload;
- maximum payload;
- over-limit payload rejected;
- invalid magic;
- unsupported version;
- unknown type;
- zero-byte input;
- truncation inside magic;
- truncation inside header;
- truncation immediately before payload;
- truncation at every payload byte boundary;
- truncation before checksum completion;
- modified payload;
- modified checksum;
- impossible length;
- extra bytes behavior explicitly defined;
- property-based round-trip;
- property-based truncation safety.

### Phase 1 exit criteria

- binary format documented;
- all codec tests pass;
- all truncation cases behave intentionally;
- arbitrary valid records round-trip;
- corrupted records do not become valid by accident;
- no storage I/O yet.

---

# Phase 2 — Segments

Implement:

```text
Tay.Storage.Segment
Tay.Storage.Writer
Tay.Storage.Reader
```

Responsibilities:

- segment ID and filename format;
- create segment;
- open existing segment;
- append record;
- sequential reading;
- rotation;
- reopen;
- durability policy.

Tasks:

1. Define segment naming.
2. Define segment discovery.
3. Define active vs sealed segment behavior.
4. Open/create active segment.
5. Append complete encoded records.
6. Implement correct handling of short writes if relevant to chosen I/O API.
7. Implement `:none`, `:flush`, and/or `:sync` semantics as approved.
8. Implement size-based rotation.
9. Ensure only one writer owns the active segment.
10. Read sequential records across a segment.
11. Read across multiple segments.
12. Define I/O failure behavior.

### Required Phase 2 tests

- create first segment;
- append one;
- append many;
- reopen;
- append after reopen;
- rotate;
- multiple rotations;
- ordered discovery;
- malformed filenames;
- duplicate IDs;
- durability API behavior;
- write error propagation;
- disk-full simulation where feasible;
- permission error behavior.

### Phase 2 exit criteria

- records survive process reopen;
- rotation is deterministic;
- active segment ownership is clear;
- sealed segments are immutable;
- all segment tests pass.

---

# Phase 3 — Recovery

Design: [approved Phase 3 recovery RFC](docs/phase-3-recovery-rfc.md), with G1–G6
resolved. Implementation requires a separate user authorization; this roadmap
reconciliation does not authorize source changes.

Implement:

```text
Tay.Storage.Recovery
```

Responsibilities:

- inspect existing initialized stores under existing-only ownership acquisition;
- discover segments and validate complete physical history and sequence ordering;
- replay every complete, physically valid, contiguous and semantically understood event, even when its prior caller acknowledgement is unknown;
- diagnose incomplete Record/footer/canonical suffix precisely and preserve all evidence;
- distinguish corruption, unsupported semantics, operational failures and resource limits;
- produce all-or-error private replay state input, never partial recovered state;
- retain the same Writer owner, native helper/Port and lock through physical preflight, semantic replay, private candidate, revalidation and mutation-capability activation;
- require a distinct post-activation admission reference for recovered-session mutations.

Recovery must never equate arbitrary parsing failure with "just truncate it".
No automatic truncation, padding, deletion, rename-aside, sequence reuse or suffix
repair is permitted. An incomplete canonical tail refuses writable activation;
automatic repair is deferred to a future separately reviewed recovery/repair
protocol, without acknowledgement metadata, repair journals, watermarks or
Phase 1/2 byte-format changes in Phase 3.

Inspection/replay must not create the root, lock, STORE, segments directory,
segment, stage or successor. A missing existing lock is an operational ownership
failure, not permission to bootstrap. No lock release/reacquire or offline
recovery ticket may authorize writer activation.

Implement only the explicit EventDecoder behaviour and test-only providers.
Production Event type/schema numbers and payload serialization, including ETF,
remain a separate future RFC/dependency. No raw-bytes production fallback is
permitted. Complete uncertain events occupy their sequences and participate in
replay; this neither proves prior caller success nor supplies exactly-once
semantics.

The RFC's recovery budgets/defaults are operational only, never persisted format
limits or physical-validity rules. Resource-limit failures leave storage
untouched and are retryable with a larger budget.

### Recovery cases

Explicitly test:

```text
[valid][valid][valid]
[valid][valid][partial header EOF]
[valid][valid][partial payload EOF]
[valid][valid][partial checksum EOF]
[valid][valid][bad checksum]
[valid][corrupt middle][valid]
```

The first is clean.
The next three must be detected safely, preserve every byte, publish no partial
recovered state and refuse writable activation. They are not automatically
repairable or evidence that sequence space is reusable. Apply the same policy
to incomplete footers and other incomplete canonical suffixes.
The last two are corruption, not ordinary interrupted append.

### Phase 3 exit criteria

- fully valid initialized histories recover automatically through the explicit semantic provider and activation gates;
- every complete, physically valid, contiguous and semantically understood event replays regardless of unknown prior caller acknowledgement;
- incomplete active tail recovers safely, with exactly the non-destructive meaning defined below;
- incomplete Record/footer/canonical suffix is diagnosed precisely, all bytes are preserved and writable activation is refused;
- unsupported semantics stop replay without skipping or publishing partial recovered state;
- sealed corruption fails clearly;
- middle corruption fails clearly;
- recovery is deterministic;
- ownership remains continuously held through revalidation and activation;
- resource-limit failures leave storage untouched and can be retried with a larger budget;
- Phase 1 Record v1 and Phase 2 Segment/STORE v1 byte contracts remain unchanged;
- torture tests pass.

“Incomplete active tail recovers safely” means:

> an incomplete active tail is detected safely, preserves all evidence, never publishes partial recovered state, never reuses occupied/ambiguous sequence space, and refuses writable activation.

It does **not** mean automatic destructive repair or automatic writable restart.
Automatic torn-tail repair is deferred to a future separately reviewed protocol,
not an incomplete Phase 3 deliverable. Production job-event recovery is likewise
not claimed by the EventDecoder behaviour and test-only providers.

---

# Phase 4 — State projection

Implement ETS-backed state reconstruction.

Modules:

```text
Tay.State.JobIndex
Tay.State.QueueIndex
Tay.State.SchedulerIndex
```

Responsibilities:

- project persisted events into logical job state;
- build ETS from replay;
- update indexes during normal operation;
- preserve the same transition rules during replay and live operation.

Important principle:

> Do not have one state-transition implementation for recovery and another incompatible one for live operation.

Prefer a shared pure projection/state-machine layer.

### Phase 4 exit criteria

- deleting ETS and replaying durable records reproduces current state;
- invalid transitions are rejected;
- queue/scheduler indexes are correct;
- replay is deterministic.

---

# Phase 5 — Job insertion

Implement durable:

```elixir
Tay.insert/1
```

Tasks:

1. Validate job.
2. Allocate stable ID.
3. Construct persisted `job_inserted` representation.
4. Append to durable storage.
5. Satisfy configured durability contract.
6. Project the event into ETS.
7. Return success only at the correct durability boundary.

The ordering of storage and ETS mutation must be explicitly designed.

Do not allow:

```text
ETS says job exists
but durable storage never received it
```

when the public API has already returned durable success.

### Phase 5 exit criteria

- insert works;
- get job works internally;
- acknowledged jobs survive restart;
- recovery recreates inserted jobs;
- insertion failure does not leave false runtime state.

---

# Phase 6 — Queue execution

Implement queue concurrency and supervised execution.

Potential modules:

```text
Tay.Execution.Queue
Tay.Execution.Producer
Tay.Execution.Executor
```

Tasks:

1. Load runnable job IDs in bounded batches.
2. Respect queue concurrency.
3. Mark/start execution according to approved durability semantics.
4. Execute worker in isolated supervised process.
5. Capture termination outcome.
6. Prevent queue coordinator from being blocked by user work.
7. Ensure crashed worker does not crash queue/storage globally.

### Phase 6 exit criteria

- jobs execute;
- concurrency is enforced;
- multiple queues operate independently;
- worker crashes are isolated;
- no unbounded mailbox accumulation.

---

# Phase 7 — Completion, failure and retries

Implement durable execution outcomes.

Persist transitions such as:

```text
job_started
job_completed
job_failed
job_retry_scheduled
job_discarded
```

Tasks:

1. Record attempt.
2. Execute.
3. Persist completion on success.
4. Persist failure information on failure.
5. Calculate retry delay.
6. Persist durable retry schedule.
7. Mark discarded after exhausted attempts.
8. Recover all these states correctly.

### Phase 7 exit criteria

- success survives restart;
- failure survives restart;
- retries survive restart;
- attempt counts are correct;
- exhausted jobs become discarded;
- crashes around outcome persistence preserve at-least-once behavior.

---

# Phase 8 — Scheduled jobs

Implement delayed execution.

Responsibilities:

- persisted `scheduled_at`;
- ordered scheduler index;
- efficient due-job lookup;
- transition due jobs to runnable state;
- recover scheduled jobs.

Do not full-scan all jobs every scheduler tick.

### Phase 8 exit criteria

- scheduled jobs do not run early;
- due jobs become available;
- restart preserves schedules;
- large numbers of future jobs do not require linear scans per tick.

---

# Phase 9 — Cancellation and administrative API

Implement:

```elixir
Tay.get_job(job_id)
Tay.cancel(job_id)
Tay.retry(job_id)
```

Cancellation rules must be explicit for each state.

For example, cancellation of currently executing jobs requires a deliberate semantic choice:

- prevent future retry only;
- attempt process termination;
- mark cancellation requested;
- another policy.

Do not improvise this silently.

### Phase 9 exit criteria

- lookup works;
- cancellation is durable;
- manual retry is durable;
- invalid transitions fail clearly;
- recovery preserves administration actions.

---

# Phase 10 — Hardening

Add:

- property tests;
- recovery torture tests;
- crash tests;
- storage compatibility fixtures;
- benchmarks;
- fault injection.

Test:

- process kill during append;
- writer kill;
- queue kill;
- executor kill;
- BEAM restart scenarios where practical;
- malformed storage;
- maximum record size;
- large replay;
- multiple segment recovery;
- disk-full behavior where feasible.

Create versioned fixture files representing storage format v1.

Future code must continue reading those fixtures or explicitly introduce a migration/version boundary.

### Phase 10 exit criteria

Tay has a defensible correctness suite for storage and recovery.

---

# Phase 11 — Snapshots and compaction

Only after the core is mature.

Implement:

```text
Tay.Storage.Snapshot
Tay.Storage.Manifest
```

Design exact snapshot/log-position semantics.

A snapshot should allow:

```text
snapshot at X
+
log after X
=
complete state
```

Compaction/segment deletion must be conservative.

Never delete a segment because it "looks old".

Deletion must be justified by durable recovery coverage.

---

# Phase 12 — Advanced orchestration

Only after durable job execution is stable.

Potential features:

- uniqueness;
- cron;
- batches;
- chains;
- workflows;
- dependencies;
- signals;
- richer telemetry;
- management APIs;
- optional web UI;
- multi-node architecture.

These features must build on existing persistence/state-machine invariants rather than bypass them.

---

# 36. Future orchestration architecture

The future shape may evolve toward:

```text
Tay
├── Storage
├── State
├── Execution
└── Orchestration
    ├── Batch
    ├── Chain
    ├── Workflow
    ├── Dependency
    └── Signal
```

Do not implement this prematurely.

The durable job engine is the foundation.

---

# 37. Engineering workflow for Codex

Codex must **not** implement the entire project in a single giant pass.

For every phase:

1. Read this file completely.
2. Inspect the repository.
3. Determine what already exists.
4. Compare it against this specification.
5. Identify contradictions or missing decisions.
6. Explain critical architecture decisions before implementation.
7. State the invariants affected.
8. List files/modules to add/change.
9. Implement only the approved/current phase.
10. Run `mix format`.
11. Run targeted tests.
12. Run the full test suite whenever practical.
13. Report exactly what commands ran.
14. Report exactly what passed or failed.
15. Do not silently change semantics to satisfy tests.
16. Do not weaken tests merely to make them green.
17. Do not modify unrelated files.
18. Stop at the current phase boundary unless explicitly told to continue.

Never claim a command or test succeeded without actually running it.

---

# 38. Rules for architectural decisions

When a design choice affects the persistent format or failure semantics, Codex must not silently decide it.

Examples:

- record framing;
- checksum algorithm;
- serialized payload format;
- fsync semantics;
- manifest semantics;
- snapshot format;
- job state transitions;
- currently-executing cancellation behavior;
- uniqueness semantics;
- compaction rules.

For such decisions:

1. present options;
2. explain trade-offs;
3. recommend one;
4. explain compatibility consequences;
5. wait for approval when the choice creates a long-lived format/contract.

---

# 39. Critical anti-patterns

Do not do any of the following:

- store durable data in `/tmp` by default;
- use ETS as source of truth;
- silently ignore corrupt log records;
- claim exactly-once execution;
- write directly to the active segment from arbitrary processes;
- scan the entire historical log to dispatch each job;
- decode unsafe arbitrary Erlang terms;
- create atoms from persisted user strings;
- bind disk compatibility directly to `%Tay.Job{}` memory layout;
- make queue GenServers execute long-running user code directly;
- consider `File.write` alone equivalent to fsync durability;
- add clustering before single-node correctness;
- add batches/workflows before recovery is trustworthy;
- optimize away correctness guarantees without benchmarks and tests.

---

# 40. Definition of "production-ready core"

Do not describe Tay as production-ready merely because jobs can run.

The durable core should at least demonstrate:

- deterministic storage framing;
- explicit format versioning;
- checksum/integrity validation;
- torn-tail recovery;
- restart recovery;
- deterministic replay;
- ETS reconstruction;
- durable insertion;
- supervised worker execution;
- durable completion/failure;
- retries;
- scheduling;
- cancellation;
- property-based codec/replay tests;
- compatibility fixtures;
- crash/failure testing;
- explicit durability semantics.

---

# 41. First Codex task

When starting from a fresh or nearly empty repository, Codex must first:

1. inspect the repository;
2. tell the user what already exists;
3. compare it against this specification;
4. identify conflicts or missing architectural decisions;
5. propose the exact scope of **Phase 0**;
6. implement Phase 0 only after that scope is clear;
7. run formatter/tests;
8. stop.

After Phase 0:

1. propose the exact scope of **Phase 1: `Tay.Storage.Record`**;
2. specify the binary framing format byte by byte;
3. explain crash/truncation detection;
4. explain checksum choice;
5. explain checksum coverage;
6. explain maximum record size strategy;
7. explain payload serialization strategy;
8. list the complete Phase 1 test matrix;
9. explain compatibility implications;
10. stop for review before writing the long-lived disk format.

---

# 42. Recommended initial prompt to Codex

Use this when opening the repository with Codex:

```text
Read TAY_PLAN.md completely before doing anything else.

Treat TAY_PLAN.md as the authoritative architecture, invariants, failure model,
and implementation roadmap for Tay.

Inspect the repository and determine the first incomplete phase.

Do not implement multiple phases at once.
Do not proceed beyond the current phase without my approval.
For persistent-format or durability decisions, present the design and trade-offs
before implementation.
Do not modify unrelated files.
Never claim tests or commands passed without actually running them.

Start by:
1. reporting the current repository state,
2. comparing it against TAY_PLAN.md,
3. identifying the first incomplete phase,
4. proposing the exact scope/files/invariants for that phase.

Then stop before implementation if the phase contains a long-lived
architecture or disk-format decision.
```

---

# 43. Recommended repository documentation layout

As Tay grows, split this master document into focused documents while keeping this file as the entry point.

Recommended future layout:

```text
docs/
├── architecture.md
├── storage-format.md
├── durability.md
├── recovery.md
├── job-state-machine.md
├── invariants.md
├── roadmap.md
└── adr/
    ├── 0001-record-format.md
    ├── 0002-checksum.md
    ├── 0003-job-id.md
    └── ...
```

Use Architecture Decision Records for long-lived decisions.

The current `TAY_PLAN.md` remains authoritative until explicitly superseded.

---

# 44. Design philosophy

Tay should aim to be simple in the places where simplicity improves trust.

Prefer:

```text
explicit state machine
explicit durable records
explicit recovery rules
explicit failure semantics
```

over:

```text
implicit magic
hidden mutation
best-effort recovery
complex generic abstractions
```

OTP should be used where it is strong:

- isolation;
- supervision;
- lifecycle management;
- concurrency;
- fault containment.

The filesystem/log layer should be treated more like a storage engine than a normal application file writer.

The core principle of the project is:

> Persist the truth, project the state, isolate execution, recover deterministically.

---

# 45. Project name

The project name is **Tay**.

The name intentionally follows the Scottish association of Oban without being a clone.

River Tay provides an appropriate metaphor for the architecture:

```text
River:
water → water → water → water

Tay:
record → record → record → record
```

The current state changes, but the durable history flows forward.

The package/module naming should remain concise:

```elixir
Tay
Tay.Job
Tay.Worker
Tay.Storage
Tay.Storage.Record
Tay.Storage.Writer
Tay.Storage.Recovery
```

Potential Hex dependency syntax:

```elixir
{:tay, "~> 0.1"}
```

---

# 46. Final instruction to contributors and agents

Do not rush Tay toward feature parity with another product.

The first goal is not "many features".

The first goal is:

```text
a small durable core
that we can trust after a crash
```

Everything else should be built on top of that.
