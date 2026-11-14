# Compaction 1.8.1 versus final 2.0.0 — 2026-11-14

Final 2.0.0 takes longer for the first compaction of this journal, but is much
faster for repeated compaction of its native checkpoint. The earlier roughly
8.1-fold improvement compared an unoptimized 2.0 implementation with its fix;
it did not establish an improvement over 1.8.1.

## Measured results

External wall-clock duration of `Tay.compact`, excluding restore, startup and
creation/completion of the additional job. Four fresh-VM trials per version per
scenario; medians below, all 24 measurements retained in [results.json](results.json).

| Scenario | 1.8.1 median | 2.0.0 median | 2.0.0 versus 1.8.1 |
| --- | ---: | ---: | --- |
| First compaction, shared bootstrap journal | 6.947 s | 10.892 s | 56.8% more time (1.57 times) |
| Native checkpoint, unchanged | 3.791 s | 0.0515 s | 73.6 times faster |
| Native checkpoint plus one completed job | 3.878 s | 0.0914 s | 42.4 times faster |

| Scenario | 1.8.1 min–max | 2.0.0 min–max |
| --- | ---: | ---: |
| Bootstrap | 6.843–6.978 s | 9.910–11.102 s |
| Unchanged checkpoint | 3.784–3.888 s | 0.0436–0.0623 s |
| Checkpoint plus one job | 3.814–4.405 s | 0.0888–0.0926 s |

The bootstrap regression is present in every trial, with non-overlapping
ranges. These results establish a regression for this workload; they do not
isolate its cause. The checkpoint improvements also occur in every trial.
They do not establish an overall application throughput or reliability claim.

## Shared data and conditions

- Baseline: clean `v1.8.1`, commit `affbfb0c0ab40e3460b023224b05c139452158fe`.
- Candidate: clean final `v2.0.0`, commit `5e4335686857ccccfc5325388b5ed87a09a8efdf`.
- One fixture seeded by 1.8.1: 10,000 completed jobs, 256-byte arguments,
  eight clients, four worker slots. History retained, no expiration.
- Bootstrap trials restore exactly the same catalog-verified backup. Each
  checkpoint scenario restores a checkpoint created by the respective engine
  from that shared dataset. Native formats/catalog hashes differ; job IDs,
  definitions and counts originate from the same fixture. Checkpoint preparation
  is outside the measurements. The one extra job is also completed before timing.
- Each scenario uses order ABBAABBA: baseline, candidate, candidate, baseline,
  repeated twice. Every trial starts a fresh VM and restores into a new directory;
  `sync -f /qualification` runs before each trial. No measured trials discarded.
- Same Linux aarch64 container, Elixir 1.20.5, OTP 29 / ERTS 17.1.1,
  GCC 14.2.0, `MIX_ENV=prod`, `ERL_FLAGS='+S 2:2 +A 2'`, separate clean builds
  and dependencies, identical lockfile. Production compilation passed with
  warnings treated as errors. Native sanitizer disabled.
- Explicit sync durability on an 8 GiB loop-backed Btrfs filesystem, mount
  options `rw,relatime,ssd,discard=async,space_cache=v2,subvolid=5,subvol=/`.
  Kernel `7.2.12-orbstack-00394-gbecdd6130068`; host macOS through OrbStack.
- Container image `tay:2.0.0-test-env`, immutable ID
  `sha256:b377e3b3165d9ffefc32f40a3fb9949adf98598cc4161aeef7a77befdfc749b7`.
- Both versions use the identical [common harness](compaction.exs), SHA-256
  `cf0f2ea7143c333cb29fb83cb1b4a91159911e1c78d84b57b080b767878f6ace`.
  Timeout is 900,000 ms for both.

After every compaction, the harness checks job counts and sampled definitions
and states, then stops the Engine completely, starts it again and repeats
verification. All 24 trials passed. Source fixture manifests and catalog hashes
were checked again at the end and remained unchanged.

## Setup costs and limits

These are compaction timings, not end-to-end restore timings. The separate
median costs below are retained to make that distinction explicit.

| Scenario | 1.8.1 restore | 2.0.0 restore | 1.8.1 startup | 2.0.0 startup |
| --- | ---: | ---: | ---: | ---: |
| Bootstrap | 3.573 s | 3.527 s | 7.330 s | 7.210 s |
| Unchanged checkpoint | 1.231 s | 4.494 s | 2.905 s | 0.0708 s |
| Checkpoint plus one job | 1.224 s | 4.428 s | 2.819 s | 0.0703 s |

In particular, faster checkpoint compaction does not imply a faster backup
restore. This experiment has four repetitions per cohort, one dataset size,
completed jobs only, and one loop-backed filesystem. It does not flush the OS
page cache or reproduce physical production storage. Live-job, expiration,
concurrent-write and larger-delta workloads require separate measurements.
Internal `pause_ms`/`total_ms` fields are preserved but are not compared across
versions because their timing boundaries differ. Sampled memory fields are
compaction-only (BEAM every 25 ms, RSS every 250 ms); brief peaks can be missed.

## Startup adaptation and reproducibility

An initial **preparation**, before measured trials, failed with
`ownership_busy` in 1.8.1. The [failure log](prepare-native-baseline.log) is
retained. The common harness was then adapted for both versions to isolate
linked startup exits and retry only that specific ownership error for up to
five seconds in 10 ms steps. It follows the repository's existing benchmark
startup-retry approach. Other errors fail immediately. Product code is
unchanged. Retries occur outside the compaction timer, and counts are recorded
as `startup_retries` and `verification_startup_retries`. Several 1.8.1 restart
verifications used one retry; all measured initial startups used zero.

The archived [runner](run.py) is the actual continuation after that preparation
failure, not a standalone provisioning script. It expects the container,
builds, common harness and seeded bootstrap/pilot fixtures to exist. Full
[command history](commands.json) includes seeding, pilots, failed preparation,
checkpoint preparation and measured trials. The [bootstrap manifest](bootstrap-fixture.json)
and [two](native-fixture-baseline.json) [native manifests](native-fixture-candidate.json)
retain catalog identities and sampled job definitions.

To repeat: check out the two pinned commits separately, build each in production
with the shared runtime/flags above, mount a disposable Btrfs filesystem at
`/qualification`, seed a bootstrap fixture once with the baseline and this
harness, then prepare each native checkpoint with its own version. Run each
scenario in ABBAABBA order on fresh restored stores, using the archived harness
and recorded CLI arguments. The binary fixtures are disposable and are not
committed. Full per-trial reports, verification outcomes and summary statistics
are in `results.json`; transient VM identifiers and paths are retained as provenance.
