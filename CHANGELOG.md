# Changelog

## Unreleased

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

- Added canonical history size in MiB, segment count, and configured terminal
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
  reconstruction, 1 GiB physical recovery, 300-segment tests and the measured
  benchmark scenarios. The R5 profile is finite and target validation is
  required; see [compatibility and limits](docs/compatibility.md).
- Limitations: no hardware-independent power-loss certification, automatic
  repair, live backup, retention/compaction, distributed execution or arbitrary
  workload/OS/filesystem support. Phase 11 snapshots/retention/compaction and
  Phase 12 orchestration/uniqueness remain deferred.

Earlier `v0.1.0`–`v0.4.0` Git tags mark development milestones, not prior public
Hex releases. See [compatibility](docs/compatibility.md) and
[operations](docs/operations.md) for the supported release boundary.
