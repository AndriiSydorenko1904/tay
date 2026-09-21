# Changelog

## Unreleased

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
