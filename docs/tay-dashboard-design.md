# Tay Dashboard v1 design

## Audit

Tay is an embedded, single-node engine. `Tay.Engine` is the sole semantic
command owner and owns all private ETS projections. `Tay.Engine.Admission`
publishes only bounded reservation and status metadata; it never publishes job
state. Recovery replays Event v1 into an in-memory candidate and constructs new
private `JobIndex`, `QueueIndex`, `TaskIndex`, and `SchedulerIndex` tables before
the engine becomes ready. The append-only log, Store v2 snapshots, and Segment
v1 framing remain authoritative.

The public facade currently supports insertion/enqueue, point lookup with
`Tay.get_job/2`, revision-checked `Tay.cancel/2` and `Tay.retry/2`, volatile
`pause_queue/2` and `resume_queue/2`, lifecycle controls, compaction, and a
bounded `Tay.status/1` snapshot. Every command is admitted through the guardian
and serialized by the engine. There is no list query or state-count API.

`Tay.Job` is the public view. Durable states are `available`, `scheduled`,
`executing`, `retryable`, `completed`, `cancelled`, and `discarded`. Its public
fields contain the stable ID, resolved worker (which can be absent after a
configuration change), stable worker key, queue, arguments, attempts, relevant
timestamps, one bounded diagnostic, immutable definition, timeout, and an
opaque generation/revision token. Manual retry is valid only for retryable and
discarded jobs. Cancellation is idempotent for cancelled jobs, conflicts for
completed/discarded jobs, and durably fences other active states. Queue pause is
volatile and prevents new claims; configured queues and slot usage already
exist in engine state.

There is no general job lifecycle telemetry dependency today. Compaction emits
bounded structured Logger metadata. The supervision tree is a host-supervised
Tay engine supervisor containing a lifecycle guardian, execution runtime,
engine, and optional compaction policy. Configuration is validated from explicit
engine options plus `Tay.Config`; Elixir 1.20 and OTP 29 are documented. The Hex
package explicitly lists core files and currently has only test/documentation
dependencies. Tests use ExUnit, disposable stores, real recovery, frozen binary
fixtures, and warning-as-error/package qualification runs.

## Public inspection API

Core adds:

```elixir
Tay.jobs(options)   # {:ok, %{jobs: [Tay.Job.t()], next_cursor: binary() | nil}}
Tay.queues(options) # {:ok, [Tay.Queue.t()]}
Tay.stats(options)  # {:ok, %{state_atom => non_neg_integer()}}
```

`jobs/1` accepts `:name`, `:timeout`, `:states`, `:queues`, `:workers`, `:id`,
`:limit`, and `:cursor`. Singular values and lists are normalized without
creating atoms. The maximum page size is 100 and the default is 50. Empty,
unknown, duplicate, or malformed filters fail with a public invalid error.
Engine unavailability uses the existing public error discipline.

Ordering is immutable insertion order, newest first, with raw job ID as the
tie-breaker. A URL-safe cursor contains a version, last scanned insertion key,
and a digest of normalized filters. It exposes no ETS continuation or Erlang
term decoding surface. A cursor is valid only for the same normalized query.

Paging is a weakly consistent live view: jobs never repeat within an unchanged
ordering traversal; inserts newer than the cursor are intentionally left for a
refresh; jobs may cease or begin matching after their key has passed. This is
preferable to holding an engine-wide snapshot. A request scans at most 1,000
ordered entries, so selective filters can return a short or empty page with a
non-nil cursor. Clients follow that cursor to continue; the API never implements
offset pagination or an unbounded scan.

## Query and index strategy

A new private, disposable `Tay.State.InspectionIndex` is part of the projection.
It stores only ordered `{inserted_at, id}` keys and aggregate counters by state,
queue, and worker key. `Projection.replace/3` updates it in the same owner
process as every other projection. `Projection.load/2` reconstructs it from the
recovered candidate, and projection validation covers it. No new durable event,
field, snapshot value, or file is introduced.

Chronological scans are bounded to 1,000 candidates per call. This consciously
does not claim constant-time compound filtering: arbitrary intersections use a
bounded scan window. State totals and queue summaries use counters and never
scan history. A future release can add compound disposable indexes without
changing the public cursor or storage format.

## Admin and queue API

The dashboard calls only the existing public `Tay.retry/2`, `Tay.cancel/2`,
`Tay.pause_queue/2`, and `Tay.resume_queue/2` functions, passing the revision
from the displayed job when mutating it. Conflict, not-found, and unknown-outcome
results are displayed as normal race outcomes. `Tay.queues/1` returns public
queue structs containing configured name/key, paused state, concurrency, and
current slot use; it does not reveal runtime PIDs or table identifiers.

## Live update strategy

Core adds generic, payload-bounded lifecycle telemetry at
`[:tay, :job, :transition]` and queue-control telemetry at
`[:tay, :queue, :control]`. Measurements are numeric and metadata contains only
the engine name, operation/state, queue key, and encoded job ID; arguments,
diagnostics, definitions, process identifiers, revisions, and storage paths are
excluded. Events fire only after the in-memory projection reflects a successful
durable transition. Telemetry is a core dependency useful to any observer.

Each connected dashboard LiveView attaches a process-specific telemetry handler
that sends itself a refresh hint for its configured engine, and detaches it on
termination. The callback performs no inspection work. The LiveView re-queries
bounded public APIs after receiving the hint. This avoids requiring a dashboard
supervision child or a particular host PubSub name, and there is no full-history
or high-frequency polling loop.

## Package and boundary

`dashboard/` is an independent Mix project and Hex package named
`tay_dashboard`, namespace `Tay.Dashboard`. It depends on `tay`, `phoenix`,
`phoenix_live_view`, and only their required transitive dependencies. Core's
Mix project never includes dashboard sources or Phoenix/Plug/LiveView
dependencies. The router macro expands to a Phoenix LiveView session mounted
inside the host endpoint; it does not start an endpoint or server.

Dashboard code may call only documented functions on `Tay`. A boundary test
rejects references to `Tay.State`, `Tay.Engine`, ETS, storage modules, and
GenServer. Core package qualification additionally asserts that its dependency
graph and archive contain no Phoenix, LiveView, Plug, or dashboard code.

## Dashboard and security

Overview displays incrementally maintained state counts. Jobs supports state,
queue, and worker-key filters, bounded cursor paging, and a details route.
Queues displays public runtime summaries and pause/resume controls. Retry and
cancel use revision-checked core calls and render races without crashing.

The package provides no authentication. Documentation mounts it behind a host
`:require_admin` pipeline. Filter parsing uses fixed state mappings and binary
keys, never dynamic atom creation. IDs and cursors go through public parsers;
malformed input becomes a user-visible error. HEEx escapes arguments and
diagnostics, and inspection output is rendered as text rather than raw HTML.

## Compatibility and release strategy

Both Elixir packages initially share version `0.8.0`. The dashboard declares a
compatible `tay` requirement and the same Elixir floor as core. It is tested
against the checked-out core through a path override while Hex metadata uses the
published package requirement. Core can still compile, release, and build a Hex
archive independently. Dashboard package checks compile a minimal Phoenix host
and inspect the archive contents.

## Risks and mitigations

- Inspection can contend with commands: page size and scan work are capped.
- Live paging races with mutation: cursor semantics are explicit and refresh is
  the reconciliation mechanism.
- Compaction can remove terminal jobs across restart: cursors remain structurally
  valid and naturally skip missing keys; clients should refresh after restart.
- Telemetry fan-out can overload observers: payloads are bounded and callbacks
  only broadcast hints.
- Host applications can expose administrative controls accidentally: no auth is
  implied, and secure router placement is prominent in the README.
- Phoenix compatibility can drift independently: dashboard has its own package,
  lockfile, tests, and compatibility declaration.

## Expected files

Core changes are limited to `mix.exs`, `mix.lock`, `lib/tay.ex`, public
inspection data modules, `lib/tay/engine.ex`, projection/index modules, tests,
README and operations documentation. `dashboard/` contains its own `mix.exs`,
formatter, README, router, LiveViews/components, optional telemetry bridge,
assets limited to static CSS where needed, and tests. No storage, Event v1,
segment, writer, recovery, or compaction codec contract changes are expected.
