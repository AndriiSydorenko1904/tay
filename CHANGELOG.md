# Changelog

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
  required; see [production limits](docs/production-limits.md).
- Limitations: no hardware-independent power-loss certification, automatic
  repair, live backup, retention/compaction, distributed execution or arbitrary
  workload/OS/filesystem support. Phase 11 snapshots/retention/compaction and
  Phase 12 orchestration/uniqueness remain deferred.

Earlier `v0.1.0`–`v0.4.0` Git tags mark development milestones, not prior public
Hex releases. See [compatibility](docs/compatibility.md),
[operations](docs/operations.md) and [packaging](docs/packaging.md) for the
supported release boundary.
