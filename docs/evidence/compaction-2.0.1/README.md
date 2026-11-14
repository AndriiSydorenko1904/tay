# Compaction 2.0.1 validation — 2026-11-14

The full checkpoint scrub reuses the pointer supplied by the root traversal,
charges each decoded snapshot once, and compares work/expiry partitions in
linear page passes. The transient partition map stores SHA-256 digests of
complete deterministic pointer encodings. Normal startup continues to load the
work index. UTF-8 validation uses Elixir's equivalent fast-ASCII algorithm.

## Repeated measurements

Each fresh VM warmed up 250 jobs, then completed 10,000 jobs with 256-byte
arguments, eight clients, four worker slots and two BEAM schedulers. Compaction
retained all terminal jobs. RSS was sampled every 250 ms and BEAM memory every
25 ms across the workload and compaction.

The macOS comparison used four trials per checkout in balanced ABBA order.
Both cohorts used the repository's `bench/release.exs` with the same single
change, `@deadline_ms 900_000`, so the slow 2.0.0 baseline could finish on this
machine. All trials are retained. This run compares the fix against 2.0.0.

| Metric | 2.0.0 median | Fixed median |
| --- | ---: | ---: |
| Compaction | 154.370 s | 19.086 s |
| Sampled peak RSS | 286.425 MB | 267.821 MB |
| Sampled peak BEAM memory | 222.366 MB | 243.041 MB |

Compaction improved by approximately 8.1 times. RSS decreased by 6.5 percent,
while BEAM memory increased by 9.3 percent. The existing comparison script
passed its 20-percent regression and 10-percent relative-MAD checks for all
six metrics. The raw aggregates retain the measured environment and every
sample. [Baseline](macos-baseline.json), [candidate](macos-candidate.json),
[comparison](macos-comparison.json), [comparison table](macos-comparison.md).

Four further Linux/Btrfs sync trials used fresh VMs and stores with the original
120-second benchmark timeout. Compaction times were
13.105, 12.894, 12.463, 11.941 seconds,
with a median of 12.679 seconds.
These are candidate-only measurements on a disposable loop-backed filesystem.
[Linux report](linux-sync.json).

## Source identity

The baseline is the clean `v2.0.0` checkout at `773dd03`. The candidate reports
record that same parent SHA and `working_tree_dirty: true`, because they were
measured before committing the fix. Candidate version is `2.0.1`. The exact
runtime source files measured have these fingerprints.

- `lib/tay/storage/v2/checkpoint_index.ex` SHA-256 `844ac087a7746eeaed6c3146bdfa02a887c1eef5fa5bf5929e5e5395225c7fcb`
- `lib/tay/event/value.ex` SHA-256 `169f2d20079bfabbadc79dd61289b953d83ee7fbaa7719ef6f476718a87a3ffe`

The macOS harness SHA-256 is recorded in its reports. To reproduce, copy
`bench/release.exs`, change only its deadline from 120,000 to 900,000 ms, compile
the baseline and candidate separately, then use `bench/release_compare.py` with
`--jobs 10000 --clients 8 --trials 4`. Compare the aggregates with
`bench/compare.py --fail-on-regression`. Linux used the original harness in
explicit sync mode with `--validated-filesystem`, with `sync -f` before each
fresh-VM trial.

## Correctness checks

- macOS core passed 757 checks, including 25 properties, with 18 optional checks
  skipped. Formatting, compilation, Dialyzer and production compilation passed.
- Linux/Btrfs sync passed 770 checks, including 25 properties, with five optional
  checks skipped, running as an unprivileged user in a writable checkout.
- Linux Phase-C default and 10,000-job retention/headroom workloads passed both
  checks. The 10,000-active-job rebuild/compact/recover check also passed.
- Standalone passed 28 checks. Strict documentation generation, Hex packaging
  and a detached production consumer release passed.
- Regression coverage rejects authenticated but inconsistent expiry keys,
  record offsets, metadata charge and extra pointer fields. UTF-8 tests cover
  long ASCII prefixes, Unicode suffixes and malformed sequences at boundaries.
