# Changelog

## Unreleased

## 0.9.1 — 2026-09-23

- Added the dashboard-enabled OCI distribution with one Tay Engine, the
  Executor Protocol Unix socket, and a self-contained Phoenix LiveView UI.
- Added a Compose example, non-root/read-only runtime hardening, Engine and HTTP
  smoke coverage, multi-architecture GHCR publishing, and complete deployment
  documentation.
- Kept built-in HTTP Basic authentication optional and disabled by default;
  deployments may enable it with a paired username/password or rely on their
  private network, loopback binding, VPN, or trusted ingress boundary.

## 0.9.0 — 2026-09-23

- Added an official minimal standalone OTP release and Debian-slim production
  image for non-Elixir Executor Protocol v1 clients, without changing the Hex
  package or embedded startup contract.
- Added strict runtime environment parsing, Engine-plus-UDS readiness checks,
  non-root/read-only container support, a generic Python worker Compose example,
  release/container lifecycle tests, and stable/prerelease-aware GHCR publishing.

## 0.8.1 — 2026-09-22

- Added the opt-in Engine option `initialize: :if_missing` for embedding
  applications that need first-start creation of a genuinely missing store.
- Kept the default existing-only startup model and fail-closed recovery: an
  existing, corrupt, partial, unsupported, inaccessible, or busy store is never
  reinitialized, repaired, replaced, truncated, or used as a bootstrap signal.
- Added an atomic native ownership operation that creates the owner lock only
  when it creates the final storage root, preventing Engine-level TOCTOU checks.

## 0.8.0 — 2026-09-22

- Added the stable, bounded public inspection API: cursor-paginated job listing,
  incremental state statistics, and public queue runtime snapshots.
- Added generic payload-bounded job-transition and queue-control telemetry.
- Added the separately published optional `tay_dashboard` Phoenix LiveView
  package with overview, job filtering/details, retry/cancel, queue controls,
  live refreshes, host-router integration, and explicit authentication guidance.
- Preserved all frozen durable storage formats and kept Phoenix, LiveView, Plug,
  HTML, and JavaScript dependencies out of the core `tay` package.

## 0.7.1 — 2026-09-22

- Fixed a circular `GenServer.call` deadlock between executor dispatch and
  completion on connections with capacity greater than one. Outbound delivery
  is now mailbox-ordered without synchronously blocking the executor server;
  durable-start ordering, completion acknowledgements, disconnect recovery,
  reservation cleanup and at-least-once execution semantics are preserved.
- Added a deterministic capacity-two dispatch/completion overlap regression
  test and a concurrent multi-capacity stress test.

## 0.7.0 — 2026-09-21

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
