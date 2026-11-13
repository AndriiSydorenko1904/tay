# Checkpoint 2.0 validation — 2026-11-13

The changed-tail checkpoint shares immutable archive files and appends changed
index paths. The first checkpoint migrates older descriptors through full
snapshot publication. These raw measurements predate the format-3
history/aggregate roots and therefore remain compaction evidence only; they are
not startup measurements. Current startup no longer rebuilds terminal DETS or
loads result bodies.

## Finite changed-tail measurements

Each run completed the stated archive cohort, published a bootstrap checkpoint,
published one unchanged checkpoint, then inserted/completed one additional job
and published the measured checkpoint. Arguments contained 16,000 payload bytes;
four callers offered work. Values below are the final pass, in bytes/ms.

| Environment | Archived jobs | Shared segment bytes | Native read bytes | New logical bytes | Admission pause ms | Total ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| macOS `:write` | 200 | 3,334,008 | 429,413 | 91,415 | 3 | 34 |
| macOS `:write` | 1,000 | 16,669,608 | 539,954 | 130,783 | 6 | 49 |
| Linux Btrfs `:sync` | 200 | 3,334,008 | 118,119 | 39,151 | 36 | 122 |
| Linux Btrfs `:sync` | 1,000 | 16,669,608 | 540,007 | 130,792 | 27 | 75 |

Job IDs are random; different insertion positions touch different leaves and
can split pages. Each row is one finite sample, not a latency percentile or
an asymptotic proof. The bootstrap still reads/writes the full retained state.
Native read tracing records requested byte lengths without payloads. New logical
bytes include index/authority metadata; shared bytes count data segments only.
Neither metric measures physical allocation or device writes.

Raw reports retain exact versions, configuration, all three passes, 5 ms memory
samples and restart observations:

- [macOS 200](macos-write-200.json), [macOS 1,000](macos-write-1000.json)
- [Linux 200](linux-sync-200.json), [Linux 1,000](linux-sync-1000.json)

## Format-3 follow-up

After adding persistent history/aggregate roots and lazy result reads, a local
macOS `:write` follow-up on 2026-11-14 used the same 16,000-byte arguments and
four callers. With 200 archived jobs, the unchanged/changed checkpoints were
24/39 ms total with 4/4 ms admission pauses; restart was 33 ms. With 1,000
archived jobs, they were 14/29 ms total with 3/3 ms pauses; restart was 23 ms.
The changed 1,000-job pass reused 16,669,608 segment bytes and read 689,391
native bytes. These are finite development samples, not latency guarantees;
the exact release SHA is qualified separately by CI artifacts.

macOS ran Elixir 1.20.4 / OTP 29 with ten schedulers. Linux ran Elixir 1.20.2 /
OTP 29 with two schedulers inside Docker, on a fresh 2 GiB loop-backed Btrfs
filesystem; the helper verified Btrfs and used explicit validated `:sync` mode.
The container overlay was not used for store data. These synthetic filesystem
checks are not hardware power-loss certification or production capacity approval.

## Verification

The final full core suite passed 751 checks (25 properties and 726 tests),
with 18 optional checks skipped; standalone passed 28 checks. The Linux Btrfs
sync selection passed 37 checks,
including changed tails, sparse-segment retention, corruption, backup/restore,
reader pins, stale CURRENT, native cleanup interruptions and publication faults.
Dialyzer, production compilation, formatting and documentation generation passed.
The format-3 follow-up core suite passed 755 checks (25 properties and 730
tests), with 18 optional checks skipped; standalone remained 28/28.

The SIGKILL test targets the BEAM owner at epoch rename, epoch parent
sync, CURRENT publication and CURRENT root sync, then verifies both shared cold
jobs and acknowledged pre-crash tail jobs after restart. A final Linux Btrfs
sync rerun passed 16 checks including the whole-VM test, old-index migration,
archive reader pins, interrupted pruning and concurrent cold reads.

Other targeted tests cover duplicate IDs, addressed retry, schedules/results,
ENOSPC and short writes, lost CURRENT replies, concurrent admission, an Engine
cold lookup deliberately queued behind a delegated reader, and restart after
partial directory removal. Reclamation remains best-effort after CURRENT and
never deletes reachable archive files to obtain candidate space.

Reproduce finite probes using a new absolute store/output path for each run:

```sh
mix run --no-start bench/run.exs --scenario compaction --mode write \
  --path /absolute/new-store --jobs 1000 --args-bytes 16000 --clients 4 \
  --output /absolute/new-report.json
```

On an independently validated Linux local filesystem use `--mode sync
--validated-filesystem`. The test-only fault suite requires `MIX_ENV=test`.
