# Changelog

## 1.6.0 — 2026-10-19

### Changed

- Converted the repository into an umbrella with independently publishable
  `tay`, `tay_http`, and `tay_dashboard` applications.
- Made installation transitive: `tay_http` installs core `tay`, while
  `tay_dashboard` installs the complete `tay_http` → `tay` stack.
- Removed Bandit, Phoenix, and LiveView from the core `tay` dependency graph;
  HTTP and dashboard users now opt into their corresponding adapter package.
- Moved HTTP worker-session state into the core executor boundary and kept the
  Protocol v1 application service transport-independent.
- Updated standalone releases, OCI builds, qualification workflows, package
  tests, and documentation for the three-application layout.

### Fixed

- Ensured clean umbrella compile and test runs build both native storage helpers
  before Tay starts, instead of depending on artifacts from a child build.
- Loaded custom Mix tasks from require-once helper files so long-running
  language servers do not report false module-redefinition diagnostics.

## 1.5.3 — 2026-10-18

### Fixed

- Applied terminal-retention compaction to finished volatile jobs in the live
  ETS projection, keeping dashboard history and in-memory accounting in sync.

## 1.5.2 — 2026-10-17

### Changed

- Clarified the top-level source-of-truth contract for persistent Store-v2 jobs
  and RAM-only volatile jobs.

### Fixed

- Updated the standalone release smoke test to verify the Store-v2 `STORE-V2`
  authority marker and `CURRENT` pointer across restart instead of expecting the
  removed Store-v1 `STORE` marker.
- Removed a 100-ms timing assumption from the blocked-recovery lifecycle test so
  slower Store-v2 startup still exercises the same synchronization boundary.

## 1.5.1 — 2026-10-17

### Added

- Added immutable per-job `:persistent` and `:volatile` durability with
  job-over-worker-over-global precedence. Volatile jobs share execution and
  accounting machinery but remain entirely in the live ETS projection.
- Added global persistent-journal group commit with bounded event-count and
  interval thresholds while retaining post-fsync acknowledgements.
- Updated `tay-client` to 1.4.0 with validated per-enqueue and decorated-task
  durability options for both Unix-socket and HTTP producers.

## 1.5.0 — 2026-10-17

### Changed

- Removed Store-v1 startup, recovery, migration, adoption, rollback, and native
  helper support. Tay 1.5.0 opens Store-v2 storage only; upgrade older stores
  with a 1.4.x release before installing 1.5.0.
- Initialized new storage directly with an empty Store-v2 generation and no
  transient Store-v1 `STORE` marker or root segment directory.
- Reworked online compaction to reconstruct its checkpoint from the sealed
  immutable Store-v2 generation at an exact durable frontier instead of copying
  Engine ETS and terminal projections.
- Allowed Store-v2 automatic retention compaction to run with active execution.
- Centralized catch-up limits, capped the in-memory online delta at 65,536 events
  and 64 MB, and exposed peak-delta, preparation, total, and net-reclamation
  measurements.

### Fixed

- Aligned the 10,000-job automatic-retention qualification with the online
  compaction policy so active scheduled and available jobs cannot indefinitely
  starve expired-history reclamation.

## 1.4.8 — 2026-10-17

### Security

- Updated Bandit to 1.13.1 for the HTTP/1 authority-validation and HTTP/2
  blocked-send fixes, removed the obsolete advisory exception, and restored
  HTTP/2 support.

### Changed

- Updated the Python client package to 1.3.2, corrected its public task-owner
  typing, and made unsupported schedule operations fail explicitly.
- Added dependency auditing, Python 3.11–3.14 testing, Python static type
  checking, and complete standalone workflow path triggers to CI.
- Kept production container examples on immutable version tags and separated
  published-image usage from local image builds.

## 1.4.7 — 2026-10-16

### Fixed

- Reclaimed transient startup and recovery heaps in the Engine, lifecycle
  guardian, and executor server after readiness is published.

## 1.4.6 — 2026-10-15

### Added

- Added live BEAM CPU utilization, online scheduler capacity, and run-queue
  pressure to the Dashboard Overview with an explicit shared-runtime boundary.

### Changed

- Replaced native reply-header offsets, field widths, and packet-allocation
  growth values with named protocol constants and a shared big-endian encoder.

## 1.4.5 — 2026-10-15

### Added

- Added human-readable, on-demand Dashboard details for storage records,
  including explanations for encoded enum values and execution tokens.
- Added offset-cursor pagination for large segment inspections.

### Changed

- Moved storage-record decoding out of the Engine command loop and added a
  bounded preview cache so inspection work cannot delay job processing.
- Bounded decoded field and raw-payload rendering to keep Dashboard pages
  responsive for large records.

### Fixed

- Made the fault-injection lock-loss cleanup unambiguous so strict GCC builds
  pass with `-Werror=misleading-indentation`.
- Removed the synchronous schedule-operation cycle between the Engine and
  Executor Server. Registrations, advancements, and cancellations now retain
  request order without blocking executor capacity polling, acknowledge only
  durable commits, and report unknown outcomes without automatic retries.

## 1.4.4 — 2026-10-15

### Changed

- Accelerated CRC32C with a table-driven implementation and added bounded
  sequential read-ahead with direct reads for large records across recovery,
  Store-v2 validation, and publication.
- Reduced native-helper allocation pressure with chunked write verification,
  streamed reply bodies, reusable request storage, and geometrically grown
  descriptor chains while preserving readback and durability checks.
- Combined append paths and avoided re-encoding records during segment
  rotation; compaction estimates now measure snapshot payloads without
  materializing them.
- Computed sealed-segment SHA-256 during the validation pass instead of reading
  each source segment a second time.
- Bounded Dashboard segment inspection to the requested record limit, using
  sealed footers or active Writer state for the total count.
- Standardized displayed and configured binary byte units as KB, MB, GB, and
  TB, where every step is 1,024; standalone configuration no longer accepts
  the `KiB`, `MiB`, or `GiB` suffixes.
- Updated the Python client package to 1.3.1 for its matching terminology
  change and release artifact.
- Replaced native protocol and fault-injection magic numbers with named,
  wire-stable constants and documented their meanings.

## 1.4.3 — 2026-10-15

### Changed

- Dashboard storage-record inspection now identifies the related job or schedule,
  revision, timestamp, and event summary. Decoded payload details can be expanded
  inline, and job identifiers link to their job page.

## 1.4.2 — 2026-10-15

### Security

- Disabled Bandit's HTTP/2 listener while a Hex release containing the fix for
  GHSA-69m6-wcv4-rwcf is pending. The acknowledged advisory is not reachable
  by Tay; HTTP/1.1 remains available.

### Fixed

- Added the missing `telemetry_metrics` production dependency to the standalone
  release lockfile.

## 1.4.1 — 2026-10-15

### Added

- Added low-cardinality `Telemetry.Metrics` definitions for command latency,
  durable transitions, group commits, engine resources, schedules, and queues.
- Added a supervised bounded poller for engine/queue gauge snapshots and an
  optional `opentelemetry_telemetry` bridge for public-command spans.

### Changed

- Public Tay commands now emit standard Telemetry `start`, `stop`, and
  `exception` span events with bounded operation/outcome metadata.
- Updated transitive dependencies, including `phoenix_pubsub` to 2.4.1 and
  `makeup` to 1.2.3.

## 1.4.0 — 2026-10-15

### Added

- Enabled Event-v2 schema-2 schedule registration, advancement, cancellation,
  and successful-result records across live persistence, Store-v1 recovery,
  Store-v2 checkpoints, compaction, and restart recovery.
- Added durable schedule inspection/cancellation APIs and a Dashboard Schedules
  page showing expression, next/last run, and lifecycle state.
- Added bounded physical record inspection for Dashboard storage segments,
  including sequence, offset, semantic type, schema, and payload size.

### Changed

- Successful remote-worker results now remain available after restart and are
  removed when compaction removes their completed job.
- Schedule declarations no longer depend on a connected client replaying them
  after an Engine or listener restart.

## 1.3.6 — 2026-10-14

### Fixed

- Deferred the Engine and Writer full-GC pass until both active and running work
  have drained, cancelled a pending idle reclaim when new work arrives, and
  avoided repeatedly collecting an unchanged idle engine.
- Allowed a fenced offline checkpoint to finish after legitimate mutations
  advance its source sequence while retaining the source-epoch fence, so an
  actual epoch replacement is still rejected.
- Kept online-checkpoint ETS snapshot cleanup within its map-shaped reference
  contract, eliminating an opaque table-identifier Dialyzer warning.
- Kept the live blocked-job count exact across retry and cancellation
  transitions instead of repairing it only on restart.

### Changed

- Added Dialyzer to continuous integration and the release qualification
  checklist.
- Removed duplicate retained-definition byte accounting from Engine state; the
  status metric now uses the compaction estimate's equivalent counter.

## 1.3.5 — 2026-10-11

### Fixed

- Preserved the `:ets.table()` type across online-checkpoint snapshot creation,
  ingestion, and cleanup so named tables and opaque table identifiers both
  satisfy the ETS contract without ElixirLS/Dialyzer warnings.

### Changed

- Reduced the Writer GenServer to API and callback routing by extracting its
  configuration, state/fail-closed handling, recovery/activation lifecycle,
  group-commit state, offline and online compaction orchestration, and physical
  segment operations while retaining a single serialized native-port owner and
  the existing durability/fault boundaries.
- Decomposed the Engine command owner into focused command, group-commit,
  persistence, projection/accounting, and online-checkpoint modules. The Engine
  remains the sole GenServer and ETS/runtime-state owner, preserving command
  ordering, durability acknowledgements, and fail-closed generation fencing.

## 1.3.4 — 2026-10-11

### Changed

- Made online Store-v2 checkpoints converge through bounded multi-round tail
  catch-up while admission remains open. The final fence is requested only for
  a small residual tail, and an overloaded builder abandons its candidate
  without replacing or poisoning the live source epoch.
- Removed full ETS list/map duplication from live checkpoint ingestion and kept
  full candidate replay outside the online publication fence. The fenced path
  now syncs the bounded final delta, atomically publishes `CURRENT`, and performs
  bounded authority validation; restart retains full canonical replay.
- Kept standalone container health green during normal online checkpoint
  `preparing` and `switching` phases while still probing the configured transport.

### Fixed

- Reopened the previous active segment and released queued enqueue calls after a
  known pre-`CURRENT` candidate failure. Ambiguous `CURRENT` outcomes remain
  fail-closed.
- Added bounded checkpoint catch-up and final-delta measurements, and made
  compaction log messages identify their normalized event and reason.

## 1.3.3 — 2026-10-11

### Fixed

- Changed periodic Store-v2 checkpoints to capture the live active and terminal
  projections at an exact durable sequence frontier instead of replaying every
  old journal segment. Checkpoints can now run with active jobs, preserve
  concurrent mutations in the ordered tail, release their temporary ETS copy
  after ingestion, and retain the existing verified atomic publication path.

## 1.3.2 — 2026-10-10

### Fixed

- Made segment rollover constant-time with respect to retained history by
  replacing foreground semantic replay with pinned identity, exact-size, CRC,
  and successor-header validation. Durable file and directory sync barriers
  remain unchanged.

## 1.3.1 — 2026-10-10

### Added

- Added configurable strict-durability group commit for concurrent enqueue
  requests via `group_commit_interval_ms` and standalone
  `TAY_GROUP_COMMIT_INTERVAL_MS`, including batch telemetry, fault/shutdown
  coverage, and a seven-interval throughput/latency benchmark recipe.
- Added standalone `TAY_DEFAULT_QUEUE_CONCURRENCY` configuration instead of a
  hard-coded execution limit of 10 for the `default` queue.
- Added standalone `TAY_CALLER_TIMEOUT_MS` configuration and preserved a
  bounded reason in HTTP `unknown_outcome` responses for diagnosis.
- Added optional periodic Store-v2 semantic checkpoints through
  `compaction: [checkpoint_interval: ...]` and standalone
  `TAY_CHECKPOINT_INTERVAL_MS`. Checkpoints publish a verified snapshot plus
  ordered tail without blocking normal preparation-time admission, skip
  unchanged state, defer while active jobs exist, and recover from the durable
  sequence frontier. Standalone enables them every 60 seconds by default; `0`
  explicitly disables them.
- Made every Overview job-status card navigate to the Jobs page with its state
  filter selected, including keyboard focus and visible hover/focus feedback.
- Released `tay-client` 1.3.0 with `retries` and `backoff` support on
  `TayHTTPWorker.task`; decorator retry settings now also act as defaults for
  `Task.enqueue` and can be overridden per submission.

### Changed

- Split Engine configuration validation into named, thematic validators and
  replaced unexplained numeric limits with documented module attributes.
- Defined zero Dashboard/API terminal retention as a one-shot full
  terminal-history compaction; active jobs remain protected and the durable
  future retention is clamped to the one-hour minimum.
- Decoupled `tay-client` releases from Tay versions. The release helper and
  PyPI workflow now skip an unchanged Python client and require its independent
  version to increase only when `clients/python/` changes.

### Fixed

- Kept the live active-memory charge ledger across online checkpoint adoption,
  made retained-byte charging stable across Event-v1 and Store-v2 projection
  fields, and fail closed on negative or divergent active accounting.
- Made enqueue wait through the short fenced checkpoint switch instead of
  returning `unavailable`, bounded by the configured caller timeout.
- Added an idle full-GC pass for the Engine and Writer after the active workload
  drains, releasing transient process heaps and binary references retained by a
  large burst.
- Included the HTTP error code in Python `ServerError` messages when Tay does
  not provide a human-readable reason, while retaining the structured `code`
  and `details` attributes.
- Aligned the OCI health-check startup grace period with Tay's 15-minute
  recovery deadline so large valid histories are not declared unhealthy while
  replay is still in progress.
- Kept the selected Dashboard theme stable across LiveView refreshes and made
  status cards use the complete dark palette during system-theme fallback.

## 1.3.0 — 2026-10-09

### Changed

- Made Event v2 the production semantic implementation while preserving all
  six frozen Event-v1 lifecycle schemas and literal bytes. The obsolete Event
  v1 facade has been removed; runtime replay works entirely through Event v2.
- Reserved and validated Event-v2 schema-2 types 7 through 10 for future
  durable schedule registration, advancement, cancellation, and successful
  result recording. Runtime emission and recovery projection are not enabled in
  this release.
- Added pull-request and main-branch CI for the Elixir and Python suites, and
  made unsafe symlinked test data roots fail fast.
- Corrected the operations documentation for online compaction.

## 1.2.0 — 2026-10-08

### Added

- Allowed `TAY_MAX_STATE_BYTES` to use integer decimal or binary size suffixes,
  such as `5GB` or `5GiB`, while preserving plain-byte values.

## 1.1.1 — 2026-10-08

### Fixed

- Restored spacing between Dashboard card grids and the explanatory text that
  follows them.

## 1.1.0 — 2026-10-08

### Changed

- Made Dashboard terminology and inline explanations understandable without
  prior Erlang/BEAM knowledge, including job states, runtime memory, active-job
  safeguards, and durable storage.
- Replaced the separate active-state byte and value-node limits with one
  `max_state_bytes` budget. The estimate now uses the job's flat BEAM heap shape,
  machine word size, retained canonical encoding, and binary payload bytes; the
  former `max_state_nodes` option remains accepted but ignored for 1.x
  configuration compatibility.
- Displayed byte values in the most readable binary unit, including KB for
  sub-MB values and GB for large limits.

### Fixed

- Preserved the expanded Storage files section across live data refreshes.

## 1.0.0 — 2026-09-30

### Added

- Released the stable Tay 1.0 engine, Python client, standalone OCI image, and
  optional LiveView dashboard.
- Stabilized the versioned storage formats, executor protocol, recovery
  behavior, and documented compatibility contracts established during the
  1.0.0 release-candidate series.

### Changed

- Promoted the validated 1.0 operating profile from release candidate to the
  stable 1.x release line.

## 1.0.0-rc.9 — 2026-09-30

### Changed

- Removed active-job and terminal-history count limits. Both Dashboard counters
  now show current counts without a maximum, and neither count can reject
  admission or trigger pressure compaction.
- Kept terminal cleanup governed exclusively by the configured time retention;
  active payload byte and value-node safeguards remain in place.
- Made a successful Dashboard compaction persist its selected terminal
  retention in Store-v2 and override the startup environment on later restarts.
- Ran Dashboard-triggered compaction asynchronously so the LiveView remains
  responsive while jobs continue to be accepted and executed.
- Buffered source-segment inspection during compaction preparation to avoid a
  native storage round trip for every record.

### Fixed

- Kept automatic compaction estimates available when persisted terminal
  retention is infinite.

## 1.0.0-rc.8 — 2026-09-30

### Fixed

- Preserved the durable availability-order frontier across online compaction so
  concurrent inserts can be replayed after expired terminal jobs are removed.
- Kept Store-v2 manifests backward-compatible while authenticating the
  allocator frontier for newly compacted epochs.

## 1.0.0-rc.7 — 2026-09-30

### Fixed

- Allowed online compaction to replay epochs containing multiple valid
  post-manifest source rotations instead of rejecting them as
  `source_segments_missing`.
- Made compaction retries publish successfully after an earlier preparation
  failure rotated the live tail while preserving the authoritative epoch.

## 1.0.0-rc.6 — 2026-09-30

### Fixed

- Synchronized Engine's physical segment frontier with Writer's source
  rotation before background compaction admits further mutations.
- Prevented valid post-rotation receipts from being rejected as
  `invalid_writer_receipt`, which previously revoked the live generation while
  compaction was preparing its candidate.
- Preserved fail-open behavior after a preparation failure even when online
  compaction had first rotated a non-empty active tail.

## 1.0.0-rc.5 — 2026-09-30

### Fixed

- Replayed Store-v2 segments through a bounded chunk cache instead of issuing
  native-owner calls for every record, keeping Writer admission responsive
  while online compaction prepares its candidate.
- Aborted failed pre-switch candidates without poisoning the authoritative
  Writer or retiring the live Engine generation.
- Preserved the existing generation and returned lifecycle state to `ready`
  when a background compaction builder fails before the atomic switch.

## 1.0.0-rc.4 — 2026-09-30

### Fixed

- Moved online-compaction source recovery out of the Engine mailbox loop so
  large terminal histories no longer block job admission and execution during
  the preparing phase.
- Replayed immutable Store-v2 segments directly in the background compaction
  builder instead of first materializing and copying the complete job map in
  Engine at the start of preparation.
- Released transient recovery and compaction heaps in the processes that own
  them, preventing terminal-history recovery memory from remaining allocated
  after activation or compaction.
- Supported online compaction when the current Store-v2 tail is empty without
  racing concurrent appends.

## 1.0.0-rc.3 — 2026-09-29

### Fixed

- Kept terminal job payloads in the disk-backed projection while serving job
  pages through a compact ordered inspection index.
- Loaded only the terminal jobs selected for the current cursor page instead
  of folding and repeatedly sorting the complete terminal history.
- Released the temporary recovery heap before the Engine enters its
  steady-state loop.
- Clarified that Dashboard state-capacity counters describe active-job
  admission limits rather than measured runtime memory.

## 1.0.0-rc.2 — 2026-09-29

### Fixed

- Throttled and coalesced Dashboard refreshes under transition-heavy workloads.
- Kept Dashboard filter controls and cursor pagination stable during live refreshes.
- Preserved HTTP enqueue rejection diagnostics, including capacity reasons.

## 1.0.0-rc.1 — 2026-09-29

### Added

- Added ergonomic Python task decorators with stable automatic or explicit
  public names, local registry lookup, argument serialization through
  `task.enqueue()`, duplicate-name protection, and synchronous/asynchronous
  handler execution.
- Added a production idempotency guide for at-least-once jobs and financial
  operations.
- Added a repeatable Tay 1.0 readiness audit harness with explicit
  PASS/FAIL/SKIP/UNKNOWN classification and isolated release artifacts.

### Fixed

- Passed the parent test build's complete dependency code path to independent
  BEAM VMs so whole-VM crash tests can start every Tay application dependency.
- Corrected the Python dependency audit to inspect the fully resolved input
  without misclassifying command-line or environment failures as
  vulnerabilities.

### Changed

- Declared the documented single-node, single-writer contracts as the Tay 1.0
  release-candidate surface. Record v1, STORE v1, Segment v1, Event v1, and the
  existing fail-closed recovery policy remain unchanged.

## 0.15.2 — 2026-09-27

### Changed

- Renamed the HTTP worker lifecycle methods to `register()` and
  `serve_forever()` to make explicit that registration alone does not process
  jobs. Kept `start()` and `run()` as deprecated compatibility aliases.

## 0.15.1 — 2026-09-27

### Fixed

- Make the HTTP-only health test probe a listening TCP port without starting a
  production-durability Store on the CI runner's unsupported `/tmp` filesystem.
  Production standalone durability remains strict `:sync`.

## 0.15.0 — 2026-09-27

### Changed

- Added mTLS-capable remote HTTP workers with long polling, execution
  acknowledgements, bounded results, cancellation events, and session expiry.
- Allow standalone HTTP-only operation with `TAY_SOCKET_PATH=off`; the local
  Unix socket remains available when local workers are desired.
- Added Python `TayHTTPWorker` for remote task execution and kept the local
  socket client available. Named the Python HTTP response and worker limits.
- Merged the dashboard into the single `tay` Hex package and moved its release
  host under `standalone/`; removed the separate dashboard package.

## 0.14.0 — 2026-09-27

### Changed

- Replaced the gRPC/Go gateway with an optional Bandit HTTP/JSON producer API
  in the Elixir Engine; Cowboy and cowlib are not dependencies.
- Added the Python HTTP/JSON producer client with mTLS support and consolidated
  the container examples into one Compose file.

## 0.13.1 — 2026-09-26

### Fixed

- Corrected Python client import ordering and formatting so the tagged source
  passes its PyPI publication checks.
- Made optional gRPC and PKCS#12 dependency checks explicit at module scope.

## 0.13.0 — 2026-09-26

### Added

- Added an opt-in gRPC producer API for enqueue, status, cancellation, and result retrieval.
- Added direct mTLS support for non-loopback gRPC listeners and Python clients,
  including a single PKCS#12 bundle option in the Python SDK.

### Fixed

- Enabled the dashboard endpoint in its HTTP test configuration and refreshed
  nested dependency locks for the new Tay gRPC dependencies.

## 0.12.0 — 2026-09-25

### Added

- Added online Store-v2 compaction with explicit `compacting/preparing` and
  `compacting/switching` lifecycle phases.
- Added regression coverage proving admission and job execution continue while
  a replacement epoch is built in the background.
- Added `TAY_TERMINAL_RETENTION` duration configuration for the standalone
  runtime, including minute, hour, and day forms such as `30m`, `24h`, and `7d`.
- Bundled the optional dashboard into the single `tay` OCI image, enabled with
  `TAY_ENABLE_DASHBOARD=true`.

### Changed

- Store-v2 compaction now rotates to a frozen frontier, builds its candidate in
  a monitored background process, journals concurrent durable mutations, and
  catches them up behind an atomic publication fence without restarting
  the Engine.
- The first Store-v1 to Store-v2 adoption remains an explicit draining
  `migrating` operation because the frozen v1 format has no safe online catch-up
  boundary.
- The dashboard reports compaction and migration as storage-maintenance states
  instead of presenting normal compaction as crash recovery.
- Container publication now produces only `ghcr.io/andriisydorenko1904/tay`;
  the separate `tay-dashboard` image is retired.

## 0.11.3 — 2026-09-25

### Changed

- Added a sustained-ingress regression test proving that a capacity-16 external
  executor refills a queue to its concurrency limit of 10 while producers
  continuously enqueue without pauses.
- Added one-command local benchmark profiles for lifecycle throughput,
  schedule lag under load, cold recovery, storage rotation and replay.

### Fixed

- Prevented sustained enqueue traffic from filling the Engine mailbox ahead of
  executor completions and queue demand. Client admission remains unchanged,
  while a guardian-owned FIFO now delivers one mutation at a time to the
  already-serialized durable Writer and yields between append boundaries.
- Fixed benchmark JSON output for tuple-valued status fields such as terminal
  retention and canonicalized macOS `/tmp` paths for native storage safety.

## 0.11.2 — 2026-09-25

### Changed

- Python clients now retain successful schedule declarations and replay them
  during every listener reconnect before advertising worker capacity or
  reporting the connection as ready.
- Scheduled occurrences now use deterministic job IDs and remain pending while
  admission is unavailable instead of being silently dropped under pressure.

### Fixed

- Restored cron and interval declarations automatically after compaction or an
  Engine restart while the declaring Python client remains alive.
- Prevented one-shot schedule ticks from disappearing when active-state
  capacity is temporarily exhausted.

## 0.11.1 — 2026-09-25

### Changed

- Automatic compaction now defers while active jobs exist, keeping ordinary
  admission available during sustained workloads.
- Terminal-count pressure now compacts to an 80% low-water mark instead of the
  exact configured maximum, preventing restart churn after each completion.
- The dashboard now explains a busy lifecycle-operation slot, displays unknown
  capacity instead of false zeroes during recovery, and refreshes automatically
  when the Engine becomes ready again.

### Fixed

- Prevented terminal-history pressure from repeatedly taking Tay unavailable
  while a large active workload was still being processed.
- Prevented a freshly loaded dashboard from remaining permanently empty after
  mounting during the compaction restart window.

## 0.11.0 — 2026-09-25

### Added

- Added a configurable `max_terminal_jobs` safety bound and standalone
  `TAY_MAX_JOBS`, `TAY_MAX_STATE_BYTES`, `TAY_MAX_STATE_NODES`, and
  `TAY_MAX_TERMINAL_JOBS` settings.
- Added dashboard runtime-memory and active/terminal capacity diagnostics.

### Changed

- Split runtime state into a hot private-ETS projection for active jobs and a
  disposable disk-backed projection for terminal inspection history.
- Made active admission limits apply only to actionable work; completed,
  cancelled, and discarded jobs no longer consume hot job/byte/node capacity,
  including after recovery.
- Kept filtered statistics, queues, job lookup, retry, and bidirectional
  pagination available across both projections.

### Fixed

- Prevented large completed/discarded histories from permanently rejecting new
  jobs with `retained_nodes` or `retained_jobs`.
- Added pressure-triggered compaction that retains the newest bounded terminal
  history without waiting for normal age, size, ratio, or cooldown gates.

## 0.10.0 — 2026-09-24

### Added

- Added a bounded catalog of the 128 newest canonical storage segments to the
  Engine status snapshot.
- Added a collapsible dashboard table with each segment's canonical filename,
  active/sealed state, size, record count, and sequence range.
- Added bounded `free`, `claimed`, `reserved`, and `submitted` client-slot
  counts to the Engine status snapshot.
- Added a backward-compatible machine-readable capacity reason to Protocol v1
  error responses and preserved it in Python `ServerError.details`.
- Added `deploy-helper.sh` to publish the version-matched container images and
  Python client through their GitHub Actions workflows.

### Changed

- Moved normal command replies to the lifecycle Guardian so it releases the
  exact submitted permit before making success or error visible to the caller.
- Expanded the project README with clearer architecture, installation, and
  deployment guidance.

### Fixed

- Fixed fast sequential producers transiently exhausting `client_slots`
  because successful replies could previously race ahead of permit release.

## 0.9.9 — 2026-09-24

### Added

- Added canonical history size in MB, segment count, and configured terminal
  retention to the dashboard Overview page.
- Added an explicit retention-hours control to manual dashboard compaction.
- Exposed the configured compaction terminal retention in the bounded Engine
  status snapshot.

### Changed

- Manual dashboard compaction now reports the selected retention alongside the
  number of removed and retained jobs and reclaimed bytes.
- Clarified that retention is time-based rather than a disk quota and that the
  displayed canonical history excludes temporary compaction headroom.

## 0.9.8 — 2026-09-24

### Added

- Added a light/dark dashboard theme that follows the operating-system setting
  by default and can be overridden with a persistent theme control.
- Added state-specific colors throughout job, queue, and overview displays.
- Added a confirmation-protected manual compaction action on the Overview page
  with a human-readable completion summary.

### Changed

- Replaced raw diagnostic maps with readable outcome titles and explanations;
  compact version/code data remains available under Technical details.
- Removed the redundant Apply filters button because LiveView applies state,
  queue, and partial worker filters as they change.

## 0.9.7 — 2026-09-24

### Added

- Added exact filtered job totals and opaque previous/next/last cursors to the
  public inspection response.
- Added complete dashboard navigation for first, previous, next, and last pages,
  including current/total page and visible/total job counts.

### Changed

- Made filtered cursor pages contain matching jobs up to the requested limit,
  including sparse partial-worker matches.
- Kept version-one job cursors readable while emitting the bidirectional
  version-two cursor format.

### Fixed

- Fixed the dashboard's one-way pagination, which previously provided no way to
  return to earlier pages or jump to the final page.

## 0.9.6 — 2026-09-23

### Changed

- Gave dashboard package publication its own committed lock file so switching
  from the local Tay checkout to the Hex dependency no longer mutates the
  development lock.
- Required Tay 0.9.5 or newer for dashboard partial worker-key filtering while
  allowing dashboard releases to version independently from the core package.

## 0.9.5 — 2026-09-23

### Added

- Added partial worker-key filtering to the inspection API and dashboard while
  preserving cursor/filter binding.

### Fixed

- Made stable schedule declarations idempotent so periodic reconciliation no
  longer resets interval timers or triggers a job on every reconciliation pass.

## 0.9.4 — 2026-09-23

### Fixed

- Included the JSON codec required by Phoenix LiveView in the standalone
  dashboard release, preventing WebSocket joins from crashing after upgrade.
- Parsed URL-encoded query parameters in the standalone endpoint so filters and
  cursor links also work during static and non-JavaScript navigation.

## 0.9.3 — 2026-09-23

### Added

- Added dashboard version, lifecycle context, attempt semantics, and readable
  diagnostic-code descriptions to job details.

### Fixed

- Fixed LiveView origin validation behind Docker port publishing and reverse
  proxies while retaining same-origin protection.
- Made job filters usable with both live events and ordinary GET submission,
  restored no-JavaScript cursor navigation, and exposed page position.
- Prevented executor connection send failures from being misclassified as
  protocol error codes and crashing the connection process.

## 0.9.2 — 2026-09-23

### Fixed

- Fixed standalone dashboard LiveView connections when accessed through local
  loopback aliases such as `127.0.0.1`, restoring interactive job filters.
- Changed job cursor pagination to use LiveView patch navigation and added
  regression coverage for distinct pages and filtered results.

## 0.9.1 — 2026-09-23

### Added

- Added the dashboard-enabled OCI distribution with one Tay Engine, the
  Executor Protocol Unix socket, and a self-contained Phoenix LiveView UI.
- Added a Compose example, non-root/read-only runtime hardening, Engine and HTTP
  smoke coverage, multi-architecture GHCR publishing, and complete deployment
  documentation.
- Kept built-in HTTP Basic authentication optional and disabled by default;
  deployments may enable it with a paired username/password or rely on their
  private network, loopback binding, VPN, or trusted ingress boundary.

## 0.9.0 — 2026-09-23

### Added

- Added an official minimal standalone OTP release and Debian-slim production
  image for non-Elixir Executor Protocol v1 clients, without changing the Hex
  package or embedded startup contract.
- Added strict runtime environment parsing, Engine-plus-UDS readiness checks,
  non-root/read-only container support, a generic Python worker Compose example,
  release/container lifecycle tests, and stable/prerelease-aware GHCR publishing.

## 0.8.1 — 2026-09-22

### Added

- Added the opt-in Engine option `initialize: :if_missing` for embedding
  applications that need first-start creation of a genuinely missing store.
- Kept the default existing-only startup model and fail-closed recovery: an
  existing, corrupt, partial, unsupported, inaccessible, or busy store is never
  reinitialized, repaired, replaced, truncated, or used as a bootstrap signal.
- Added an atomic native ownership operation that creates the owner lock only
  when it creates the final storage root, preventing Engine-level TOCTOU checks.

## 0.8.0 — 2026-09-22

### Added

- Added the stable, bounded public inspection API: cursor-paginated job listing,
  incremental state statistics, and public queue runtime snapshots.
- Added generic payload-bounded job-transition and queue-control telemetry.
- Added the separately published optional `tay_dashboard` Phoenix LiveView
  package with overview, job filtering/details, retry/cancel, queue controls,
  live refreshes, host-router integration, and explicit authentication guidance.
- Preserved all frozen durable storage formats and kept Phoenix, LiveView, Plug,
  HTML, and JavaScript dependencies out of the core `tay` package.

## 0.7.1 — 2026-09-22

### Fixed

- Fixed a circular `GenServer.call` deadlock between executor dispatch and
  completion on connections with capacity greater than one. Outbound delivery
  is now mailbox-ordered without synchronously blocking the executor server;
  durable-start ordering, completion acknowledgements, disconnect recovery,
  reservation cleanup and at-least-once execution semantics are preserved.
- Added a deterministic capacity-two dispatch/completion overlap regression
  test and a concurrent multi-capacity stress test.

## 0.7.0 — 2026-09-21

### Added

- Executor Protocol v1 now has automatic, cross-language local socket discovery:
  explicit path, `TAY_SOCKET_PATH`, XDG runtime, `TMPDIR`, then per-UID `/tmp`.
  Normal Engines and `Tay()` therefore connect without socket configuration;
  automatic directories are private and `executor_socket: nil` is the explicit
  listener opt-out. Stale cleanup now verifies the Unix socket file type before
  unlinking and refuses arbitrary filesystem objects.
- Added an opt-in, Unix-domain-socket-only Executor Protocol v1 listener with
  bounded framed JSON, explicit hello/register/capacity lifecycle, per-task
  dispatch selection, durable enqueue/status/cancel bridging, timeout fencing,
  disconnect recovery and bounded live-generation result retention.
- Added the separately packaged, stdlib-only `clients/python` SDK. It supports
  producer, embedded and dedicated worker modes, task decorators, reconnecting
  task registration, JSON validation, bounded result/error reporting and the
  `tay-worker` entry point.
- Preserved the frozen Record/Segment/Event v1 format. Result values are not
  invented as Event-v1 fields: only completion is durable, while successful
  values are retained up to `executor_max_results` in the current listener
  generation. Durable periodic scheduling and custom retry policies remain
  deferred.
- Centralized the immutable Event-v1 retry delay/jitter constants so all retry
  producers and interval checks use the same frozen policy.

## 0.5.0 — first public preview

### Added

- Durable single-node job core: frozen Record v1 and Segment/STORE v1 framing,
  canonical Event v1 semantics, an authoritative append-only log, bounded
  admission, same-ID insertion reconciliation and disposable ETS projections.
- Supervised execution lifecycle: scheduling, automatic bounded retries,
  revision-checked cancellation/manual retry, queue pause/resume, drain and
  explicit fresh-generation stop/restart. Worker effects are at-least-once;
  neither exactly-once external effects nor multi-node execution is supported.
- Fail-closed recovery: complete contiguous understood events replay even when
  prior caller acknowledgements are unknown. Torn, corrupt or unsupported
  history preserves evidence and refuses writable activation; no automatic
  tail repair, truncation or partial-state publication is provided.
- Qualification: unchanged binary/Event fixtures, macOS development and
  validated Linux/Btrfs strict-sync ordinary suites, ASan/UBSan, independent
  crash/race and cold-restore tests, detached consumer releases, 10,000-job
  reconstruction, 1 GB physical recovery, 300-segment tests and the measured
  benchmark scenarios. The R5 profile is finite and target validation is
  required; see [compatibility and limits](docs/compatibility.md).
- Limitations: no hardware-independent power-loss certification, automatic
  repair, live backup, retention/compaction, distributed execution or arbitrary
  workload/OS/filesystem support. Phase 11 snapshots/retention/compaction and
  Phase 12 orchestration/uniqueness remain deferred.

Earlier `v0.1.0`–`v0.4.0` Git tags mark development milestones, not prior public
Hex releases. See [compatibility](docs/compatibility.md) and
[operations](docs/operations.md) for the supported release boundary.
