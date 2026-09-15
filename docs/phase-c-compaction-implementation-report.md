# Store-v2 compaction Phase C implementation report

Status: **PHASE C COMPLETE — qualified 2026-09-15**.
Qualified baseline: Phase-B commit `2cfe8c3`. This reconciled report supersedes
the stale intermediate implementation/qualification lists. RFC:
`docs/storage-compaction-rfc.md`. No online or post-Phase-C feature is included.

## Continuation state and final changes

At this continuation the main implementation was already present: finite
MANIFEST policy, shared validation, bounded manual API, strict configuration,
automatic policy child, tokenized timer, asynchronous Lifecycle permit,
conservative estimator, generation/frontier checks, recovered accounting,
manual/automatic serialization, bounded events, fixtures and focused tests.
Deferred reclamation, startup reclamation, sole-Writer ownership and lost-CURRENT
reconciliation were already accepted Phase-B functionality and remain intact.

This continuation added deterministic stopping/recovering/stopped, live public
drain, ownership-loss/fresh-evaluator, pending-estimate shutdown and stale-result
regressions; automatic-versus-manual slot contention; and a real 10,000-job
automatic-retention qualification with exact recovery and estimator assertions.
Its Linux variant creates an external disposable disk reservation to exercise
actual free-space refusal, removes only that reservation and retries normally.
The qualification workflow now includes this explicit expensive gate.

One proven production correction: MANIFEST capture precedes construction, so it
cannot alone anchor cooldown since successful publication. Engine activation now
uses `max(verified_capture_time, activation_wall_time)`. Restart can extend, never
shorten, cooldown. Durable captured time and authority bytes are unchanged.
A deterministic delayed-publication regression covers this rule.

Final automatic-drain shutdown coverage exposed a second production bug: execution
prediction after V2 publication used the V1 map/physical-sequence transition,
which requires `available_sequence`, absent from V2 jobs. Execution prediction,
encoding and settlement preflight now use existing V2 logical reducer/codec
when the selected epoch is V2, preserving the V1 path unchanged. The regression
also completes a V2 callback and checks logical revision 3 before shutting down
the next eligible automatic request while execution is still pending. The
final results below have been rerun after this fix; standalone
native/large-storage results remain valid.

The first Linux headroom run correctly deferred twice before succeeding because
Btrfs deferred freeing an unlinked external reservation. Its exact-count assertion
failed (103 instead of 102 evaluations). The harness now syncs the dedicated
filesystem and verifies actual space release before retry. No source is deleted,
no durability validation relaxed. A subsequent pre-fix ordinary rerun also exposed
the execution regression and one isolated `:killed` startup in the existing closed
failed-Port regression. The exact failing ordinary seed 356422 now passes all
666 tests; the supplementary isolated repeat passes 5/5. Failed historical runs
are not counted as passes. The startup exit remains an isolated observation,
not evidence of authority rollback or damaged-store acceptance.

An earlier default qualification failure was legitimate retained-state admission:
550 definitions of 250 kB could not fit the unchanged 268,435,456-byte budget
before two 64 MiB segments sealed. Only provisional `min_sealed_segments` changed
from two to one. The qualifying 340-job cohort fits existing limits; no state,
event, segment or validation limit was loosened. Pre-change whole suites are
historical, not final acceptance evidence.

One new shutdown test incorrectly assumed a suspended Engine needed resuming;
OTP processes shutdown while suspended. The assertion now proves both evaluator
and Engine die and recovery preserves authority. No production change or weaker
durability assertion was needed. Earlier transient syntax/type/test-expectation
failures were corrected, never suppressed; all final gates use warnings as errors.

## Final architecture and contracts

### MANIFEST and retention

The explicitly approved amendment changes only the Value in existing schema-1
`terminal_retention`: unchanged `"infinity"`, or exact one-key map
`%{"hours" => h}`. No added key, schema version, Record/Segment framing, CRC,
SHA binding, CURRENT or STORE-V2 layout. Released V1/V2 fixtures remain unchanged;
new Phase-C literals are separate. Phase C reads infinite Phase-B stores;
older bounded-unaware readers may fail closed, never reinterpret bounded bytes.

`Retention.max_hours = floor(9_223_372_036_854_775_807 / 3_600_000)
= 2_562_047_788_015`. Integers only, positive and bounded. Duration arithmetic
is checked against signed durable time. Configuration, API, manifest decoding
and snapshot classification share the validator; invalid policy has no fallback.

One captured wall time and policy govern the whole candidate. Only completed,
cancelled and discarded terminals with durable `terminal_at <= captured_at -
duration` expire, including equality. Scheduled, available, executing, retryable
and unsettled jobs are protected. Missing/invalid terminal metadata fails closed.
Expired IDs get not-found from get/retry/cancel, including old revision handles;
a later insert with that ID is a new job, not retained tombstone history.

Publisher constructs snapshots one payload at a time with existing bounded
source/candidate admission; it does not use the pure whole-epoch builder in
production. Candidate replay and exact retained semantic equivalence precede
publication. Lost-CURRENT reconciliation uses that same captured retained view.

### Configuration and qualified defaults

```elixir
compaction: [
  enabled: true,
  terminal_retention: {:hours, 24},
  check_interval: 60_000,
  min_interval: 3_600_000,
  min_sealed_segments: 1,
  min_reclaimable_bytes: 16_777_216,
  dead_ratio_threshold: 0.25
]
```

`compaction: false` removes the evaluator/timer, explicitly leaving history
management to the operator. Strict keyword validation rejects unknown/duplicate
keys, nonboolean enablement, invalid durations, infinity for automatic retention,
nonpositive/unbounded intervals/counts/bytes and invalid ratios. Intervals/counts
fit unsigned 32 bits; byte thresholds fit signed durable integer range; finite
numeric ratios are in `(0, 1]`.

Manual `Tay.compact/1` uses the production permit/drain/Writer path. Omitted
retention uses configured finite policy; explicit `:infinity` is an administrative
retain-all choice. No force option bypasses safety.

Default evidence: 24 hours separates 8,000 25-hour-old terminals from 1,000
recent ones and 1,000 protected jobs in the 10,000 profile, with exact restart
verification. One sealed segment allows useful work within unchanged state
limits; two did not. The 16 MiB / 0.25 conjunctive gates admit both qualified
rotation workloads and the mixed 10,000 profile, but refuse minimal generations
and unproven benefit. One-hour cooldown is boundary/backward-clock tested and
anchored after publication; it limits repeat stop-the-world work. Sixty-second
checks coalesce with no outstanding-operation timer; 100 idle checks never
churn CURRENT. Measured capped estimator CPU and loaded evaluator costs below
are tiny relative to that interval. These are finite software workload evidence,
not a universal latency/capacity guarantee or exact deletion schedule.

### Evaluator, estimator and ownership

Exactly one `CompactionPolicy` child per enabled Engine group; one cancellable,
tokenized timer. Rearm only after result. Stale timers, estimates and operation
results are ignored; early valid delivery cancels its original timer. Recovery
creates no evaluator until Engine activation. Administrative generation replacement
invalidates pending estimates while an actual publication must settle normally.
Fresh group startup discards volatile state and reconstructs it once during replay.

Engine maintains acknowledged definition-byte/job totals and at most 128 oldest
hourly terminal buckets. Startup decorates terminal time during existing replay;
ordinary acknowledgements update contributions. Periodic checks fold only bounded
buckets, not jobs or files. Missing metadata defers, never triggers periodic replay.
Only fully expired buckets count; dropping buckets reduces claimed expiry.
Snapshot upper bound is definition bytes plus 512 per retained job; add 1 MiB
fixed allowance and 256 per possible source/base entry. Reclaimable lower bound
uses only sealed source bytes minus candidate upper bound. Active-tail bytes are
excluded. The owner still obtains actual additional disk headroom independently.

Bounded property tests independently encode snapshots and MANIFEST with worst
one-segment-per-snapshot framing and 0..150 source segments. Generated empty,
active/mixed, expired/nonexpired cases and all scalar/state profiles prove the
upper bound dominates candidate bytes and lower bound cannot overclaim benefit.
Nonexpired cases qualify structural supersession through the same independent
bound, not an expiry guess. Retry removes terminal contributions; unavailable
metadata defers. Recovery/policy changes use the shared summary rule. Production
candidate admission tests include rotations and 900 kB snapshots. The actual
10,000 automatic candidate also satisfies the recovered estimator bounds.
Worst capped summary: 1,498 words, independent of retained job count.

Lifecycle alone claims the existing fixed operation slot, closes admission and
drains/settles execution. Expected generation/frontier is checked at admission
closure, before drain; legitimate settlement can advance the frontier afterward.
Writer pins/replays the final settled source under the existing sole native lock;
epoch identity is rechecked. Automatic and manual operations cannot overlap.
Unable-to-drain automatic work returns a bounded deferral and restores ready
admission without forcing callback death. Health/busy/draining/recovering/stopping
and stale-source cases never enter unsafe publication.

Supervisor shutdown cancels timers and requests owner-local construction
cancellation. Before CURRENT this may preserve old authority with deferred cleanup;
once CURRENT starts, verification/reconciliation must finish irrespective of caller
deadline. Shutdown waits for that durable outcome, not for a driver that requires
the same shutting-down supervisor. Post-publication reclamation can defer;
startup safely resumes it, never rolling CURRENT backward.

### Observability

Structured Logger metadata emits evaluation_performed, evaluation_skipped,
compaction_eligible, compaction_deferred, automatic_compaction_started,
automatic_compaction_completed and automatic_compaction_failed. Whitelisted
numeric bytes/counts/durations only; no args, definitions, IDs, recovered maps or
unbounded errors. Fixed reasons cover thresholds, cooldown, busy, all lifecycle
states, headroom, unhealthy/unavailable/stale source, drain, publication and unknown
outcome. Automatic replies are sanitized before reaching evaluator state.

## Final qualification commands and results

macOS arm64, Elixir 1.20.2 / OTP 29.0.2. All listed final commands passed.
Expected injected helper/session-failure logs are not
assertion failures. Mix sandbox TCP build-lock denial was rerun with escalation.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix test --warnings-as-errors
TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors
TAY_PHASE_C_WORKLOAD=1 mix test test/tay/engine/compaction_runtime_test.exs --only phase_c_workload --warnings-as-errors
TAY_PHASE_C_10000=1 mix test test/tay/engine/compaction_runtime_test.exs --only phase_c_10000 --warnings-as-errors
git diff --exit-code -- test/fixtures lib/tay/event.ex lib/tay/event lib/tay/storage/record.ex lib/tay/storage/segment.ex c_src/tay_storage_helper.c
git diff --check
```

Format, development/test/production compilation and frozen/native/diff checks:
exit 0. Final ordinary: **657 passed** (24 properties, 633 tests), **17 gated
skips**, zero failures, seed 946422, 89.8 s. Detached consumer/release: **1 passed**,
seed 504562, 6.4 s, deployed Mach-O arm64 helper, TAY_PACKAGE_RELEASE_OK marker;
compiler/Mix/system Erlang absent from deployed runtime PATH.
Default automatic workloads: **2 passed**, 23 excluded, seed 855589, 96.8 s.
Automatic 10,000: **1 passed**, 24 excluded, seed 461847, 148.5 s.

Exact focused command (final source/tests):

```sh
mix test test/tay/engine/compaction_policy_test.exs test/tay/engine/compaction_runtime_test.exs test/tay/engine/compaction_test.exs test/tay/storage/v2_authority_test.exs test/tay/storage/v2_epoch_test.exs test/tay/storage/v2_retention_test.exs test/tay/storage/v2_phase_a_test.exs test/tay/storage/v2_refusal_test.exs test/tay/storage/v2_native_test.exs test/tay/storage/v2_v1_migration_test.exs test/tay/storage/v2_property_test.exs test/tay/storage/v2_fault_matrix_test.exs test/tay/storage/v2_vm_crash_test.exs test/tay/storage/record_fixture_test.exs test/tay/event/codec_test.exs test/tay/storage/recovery_test.exs test/tay/storage/recovery_adversarial_test.exs test/tay/storage/recovery_semantics_test.exs test/tay/storage/recovery_lifecycle_test.exs test/tay/storage/recovery_property_test.exs test/tay/system/independent_crash_matrix_test.exs --warnings-as-errors
```

**225 passed** (9 properties, 216 tests), **5 gated skips**, zero failures,
seed 717129, 60.9 s. Covers C config/policy/runtime/literal fixtures, all A/B V2
regressions, frozen V1 codec/record bytes, recovery/property/adversarial matrices,
publication/reclamation faults and independent whole-VM crash matrices.

### Linux/Btrfs strict sync

Disposable privileged setup, read-only host mount; test processes run as `nobody`
on verified local loopback Btrfs, `TAY_TEST_SYNC=1` and validated-filesystem strict
`:sync`. Final container command executed:

```sh
docker run --rm --privileged --mount type=bind,src=/Users/snake/projects/tay,dst=/work,readonly elixir:1.20.2 sh -lc 'set -eu; apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq btrfs-progs >/dev/null; truncate -s 1G /tmp/tay-final.img; mkfs.btrfs -q /tmp/tay-final.img; mkdir /mnt/tay-btrfs; mount -o loop /tmp/tay-final.img /mnt/tay-btrfs; mkdir /mnt/tay-btrfs/data /tmp/tay-checkout; test "$(stat -f -c %T /mnt/tay-btrfs)" = btrfs; tar -C /work -cf - lib c_src test bench scripts docs config clients mix.exs mix.lock .formatter.exs LICENSE CHANGELOG.md README.md .github deps | tar -C /tmp/tay-checkout -xf -; chown -R nobody:nogroup /tmp/tay-checkout /mnt/tay-btrfs/data; runuser -u nobody -- env MIX_HOME=/tmp/tay-mix HEX_HOME=/tmp/tay-hex TAY_TEST_DATA_ROOT=/mnt/tay-btrfs/data TAY_TEST_SYNC=1 MIX_BUILD_PATH=/tmp/tay-checkout/_build ERL_FLAGS="+S 4:4 +A 4" sh -lc "set -eu; cd /tmp/tay-checkout; mix local.hex --force; mix format --check-formatted; mix compile --warnings-as-errors; MIX_ENV=test mix compile --warnings-as-errors; mix test --warnings-as-errors --seed 356422; MIX_ENV=prod mix compile --warnings-as-errors; TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors; mix test test/tay/engine/compaction_runtime_test.exs test/tay/engine/compaction_policy_test.exs test/tay/storage/v2_retention_test.exs test/tay/storage/v2_authority_test.exs test/tay/storage/v2_fault_matrix_test.exs test/tay/storage/v2_vm_crash_test.exs --warnings-as-errors; TAY_PHASE_C_WORKLOAD=1 mix test test/tay/engine/compaction_runtime_test.exs --only phase_c_workload --warnings-as-errors; TAY_PHASE_C_10000=1 TAY_PHASE_C_HEADROOM=1 mix test test/tay/engine/compaction_runtime_test.exs --only phase_c_10000 --warnings-as-errors"'
```

Format/dev/test/prod compile: passed. Ordinary: **666 passed** (24 properties,
642 tests), **8 gated skips**, seed 356422, 83.1 s. Detached strict-sync consumer
and production release: **1 passed**, seed 85192, 4.0 s, deployed ELF aarch64
helper; TAY_PACKAGE_SYNC_LIFECYCLE_OK and TAY_PACKAGE_RELEASE_OK markers.
Final focused runtime/policy/retention/authority/fault/whole-VM command:
`mix test test/tay/engine/compaction_runtime_test.exs test/tay/engine/compaction_policy_test.exs test/tay/storage/v2_retention_test.exs test/tay/storage/v2_authority_test.exs test/tay/storage/v2_fault_matrix_test.exs test/tay/storage/v2_vm_crash_test.exs --warnings-as-errors`:
**50 passed** (2 properties, 48 tests), 3 gated skips, seed 24943, 26.2 s.
Automatic defaults: **2 passed**, 23 excluded, seed 235219, 76.0 s.
Final automatic 10,000 plus actual free-space refusal: **1 passed**, 24 excluded,
seed 254593, 124.1 s. Exactly one actual headroom deferral and one successful
publication; 102 evaluations, 100 no-ops, CURRENT unchanged afterward.

Supplementary isolated closed-Port startup regression repeated five times in
separate Linux write-mode disposable stores (not the headroom-reserved Btrfs
volume): **5/5 passed**, seed 356422, 0.1–0.2 s per test. Exact inner command:
`for run in 1 2 3 4 5; do mix test test/tay/engine/compaction_test.exs:103 --warnings-as-errors --seed 356422; done`.
Environment: `TAY_TEST_DATA_ROOT=/tmp/tay-port-checks TAY_TEST_SYNC=0
MIX_BUILD_PATH=/tmp/tay-checkout/_build/port-check`, nobody, four schedulers.
The strict Btrfs full suite also passes this regression at the original seed.

### Large / 1 GiB and sanitizer provenance

Established large gate executed in the preceding 8 GiB verified Btrfs container,
with the same nobody/strict-sync environment and current storage/native source:

```sh
TAY_LARGE_SEGMENT_TEST=1 TAY_LARGE_RECOVERY_TEST=1 mix test test/tay/storage/segment_large_test.exs test/tay/storage/recovery_large_test.exs test/tay/engine/large_recovery_test.exs --warnings-as-errors
```

**4 passed**, zero failures, seed 164691, 381.8 s. Three inherited storage cases
include exact 1 GiB geometry and real 1 GiB bounded-read replay/activation with
constant-size recovery candidate. The fourth is historical B manual 10,000
reconstruction, not a substitute for C automatic qualification. That manual run
reported source 4,320,152; candidate 5,750,817; admitted 6,799,240; pause 7,460 ms;
Writer 69,415,800; reclaimed 4,320,152. The later cooldown-only Engine change
and execution-preflight changes do not affect the three standalone storage cases
or execution-disabled manual reconstruction; no expensive ceremonial
storage rerun was needed. Prior accepted macOS large gate: 3 passed, seed 155693,
452.5 s, documented in the Phase-B report.

`c_src/tay_storage_helper.c` is byte-identical to qualified Phase B (empty git
diff). Current native source retains accepted ASan/UBSan results: macOS 623
passed, seed 54773, 115.7 s; Linux/Btrfs 632 passed, seed 374134, 86.0 s;
zero sanitizer findings, `-fsanitize=address,undefined`. Source unchanged means
those results remain valid; no ceremony-only sanitizer run was performed.
The Elixir Native change is a volatile cancellation check, not a C/protocol change.

### Fault/crash and deterministic race coverage

Existing matrix preserved: candidate begin, base/frame/footer/seal/sync, empty
tail, manifest write/sync/validation, epoch rename/parent sync, adoption intent/
move/marker/rollback, staged CURRENT write/sync, replacement/root sync/post-read,
first mutation, tail rotation and reclamation. ENOSPC, short writes, syscall
errors and helper crashes fail closed. Reclamation sites 258–269 cover every
segment/manifest/directory/epoch unlink and parent sync, adoption intent/marker
cleanup and rollback. Partial V2 A→B predecessor deletion resumes on startup
without changing B semantics; CURRENT is never deleted or rolled back.

Whole-VM suite now covers 18 independent child SIGKILL trials: six original
publication/adoption sites, four predecessor-reclamation sites, eight additional
bounded-retention publication/reclamation sites. Restart selects old exact state
or new exact retained state, never a merge/mtime guess. These run in final ordinary
and focused suites; Linux child preludes now honor strict-sync validation.
Existing cross-process locks, frozen-source races, corruption/ordering/profile/
tail/topology refusals preserve bytes without repair/truncation/padding.

C deterministic tests cover busy/manual-active, automatic/manual contention,
draining/drained, stopping/stopped, recovering, ownership loss/unhealthy,
inability to settle a live callback and safe retry, stale generation/frontier,
fresh evaluator and administrative generation replacement, pending-estimate
shutdown, stale timers/estimates/results, and shutdown/deadline at before-candidate,
base-write, epoch-published, before-CURRENT and CURRENT-published boundaries.
Lost CURRENT reply during expiry and shutdown exercises actual reconciliation.

## Measurements

### Actual 10,000-job automatic retention (final macOS and Linux)

Streamed disposable V1 production-event history: 19,000 events, default 64 MiB
rotation, ordinary limits; 8,000 expired cancelled, 1,000 recent cancelled,
500 scheduled and 500 available. Unknown workers/execution-disabled fixture
keeps protected states stable; the separate default cohorts below use real
execution settlement. This fixture preparation is not the compaction operation:
the useful compaction is initiated by the actual default evaluator and follows
the exact production Lifecycle/Writer path.

| Measurement | macOS | Linux/Btrfs strict sync |
| --- | ---: | ---: |
| Retention | 24 hours | 24 hours |
| Source / reclaimed bytes | 85,873,260 | 85,873,260 |
| Candidate bytes | 17,214,886 | 17,214,886 |
| Candidate/source | 0.20046852768836307 | 0.20046852768836307 |
| Sampled logical disk peak bytes | 103,088,174 | 103,088,174 |
| Sampled logical peak/source | 1.2004688537502828 | 1.2004688537502828 |
| Publisher construction/publication pause | 22,220 ms | 13,414 ms |
| End-to-end useful automatic operation | 86,361 ms | 33,178 ms |
| Writer process sample peak | 25,453,576 bytes | 33,452,296 bytes |
| Publisher's own Writer sample peak | 23,880,352 bytes | 33,452,352 bytes |
| Whole-VM total sample peak | 503,276,333 bytes | 484,657,449 bytes |
| Evaluations / no-ops / publications | 101 / 100 / 1 | 102 / 100 / 1 |
| Actual headroom deferrals | 0 | 1 |
| Evaluation duration sum / maximum | 3,299 / 1,628 us | 4,582 / 1,230 us |
| Exact recovered survivors | 2,000 | 2,000 |

Every ID checked before and after fresh startup: no expired resurrection or
protected loss. Actual candidate is below the independently calculated estimator
upper bound; claimed benefit is below actual source minus candidate. CURRENT
unchanged after 100 post-restart checks at cooldown equality. Evaluation durations
are actual async request/result elapsed time, not the test polling delay.
Logical peaks are stable owner-held filesystem-size samples including staged
metadata, not device allocation peaks. Writer heap/process and whole-VM total
are sampled scopes, not native RSS or proven absolute peaks; test observers also
consume VM memory. End-to-end includes drain, sealing/replay, construction,
publication, reclamation and controlled generation recovery; Publisher pause alone
must not be represented as the total stop-the-world maximum.

### Production-default and minimum-rotation cohorts

All old terminals expire; one real callback remains executing during first
automatic request. Deterministic inability-to-drain deadline defers, preserving
callback/admission/source; retry settles callback and retains its fresh completion.
Each profile publishes once and passes 100 no-churn checks.

| Profile | Source/reclaimed | Candidate | Lower estimate | macOS pause / total | Linux pause / total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Default 64 MiB, 340 expired + 1 completed | 85,212,626 | 1,527 | 65,866,244 | 7,139 / 40,666 ms | 5,677 / 30,067 ms |
| Minimum rotation, 160 expired + 1 completed | 40,100,774 | 1,596 | 32,032,126 | 3,546 / 19,351 ms | 2,644 / 14,008 ms |

Default logical peak 85,214,181, ratio 1.0000182484694229; Writer sample
1,115,480 macOS / 2,918,048 Linux (Publisher own sample 2,918,560 Linux).
Referenced-binary samples 254,863,426 / 188,915,708 bytes: these are
references/shared buffers, not additive heap or
unique allocated RAM. Minimum logical peak 40,102,398, ratio
1.0000404979714357; Writer barrier peak 372,720 macOS / 1,115,296 Linux.

Capped estimator 10,000 CPU checks: final focused macOS 36,421 us; final ordinary
macOS 24,836 us; Linux 34,879 us. Memory 1,498 words. Idle 100-check test verifies
cancelled prior timers, zero evaluator mailbox backlog and no CURRENT creation.
Loaded exact async 101-check measurements are in the 10,000 table.
Inherited 300-segment regression: source/reclaimed 162,044; candidate 193,948;
admitted 1,298,284; final focused macOS pause 857 ms / total 2,398 ms / Writer
2,917,992; Linux ordinary pause 224 ms / total 879 ms / Writer 3,147,488.
Larger candidate here is not useful automatically; the conservative gate refuses
unproven benefit rather than rewriting merely because many segments exist.

## Exact files changed from qualified Phase B

Existing files: `.github/workflows/qualification.yml`, `README.md`,
`docs/compatibility.md`, `docs/operations.md`, `docs/storage-compaction-rfc.md`,
`lib/tay.ex`, `lib/tay/engine.ex`, `lib/tay/engine/config.ex`,
`lib/tay/engine/lifecycle.ex`, `lib/tay/engine/operations.ex`,
`lib/tay/engine/supervisor.ex`, `lib/tay/storage/native.ex`,
`lib/tay/storage/v2/authority.ex`, `lib/tay/storage/v2/publisher.ex`,
`lib/tay/storage/v2/snapshot.ex`, `lib/tay/storage/writer.ex`,
`test/tay/storage/v2_vm_crash_test.exs`.

New files: `docs/phase-c-compaction-implementation-report.md`,
`lib/tay/engine/compaction_config.ex`, `lib/tay/engine/compaction_estimate.ex`,
`lib/tay/engine/compaction_events.ex`, `lib/tay/engine/compaction_policy.ex`,
`lib/tay/engine/compaction_replay.ex`, `lib/tay/storage/v2/compaction_control.ex`,
`lib/tay/storage/v2/retention.ex`, `test/tay/engine/compaction_policy_test.exs`,
`test/tay/engine/compaction_runtime_test.exs`, `test/tay/storage/v2_retention_test.exs`,
`test/support/compaction_metrics.ex`,
`test/fixtures/storage/v2/phase_c/README.md`,
`test/fixtures/storage/v2/phase_c/manifests.hex`,
`test/fixtures/storage/v2/phase_c/current.hex`.

This continuation's two production fixes touch only `lib/tay/engine.ex`; associated
documentation/race/workload/measurement changes touch `docs/operations.md`, this
report, the qualification workflow, runtime/policy tests and new metrics helper.

## Known limitations and acceptance

Stop-the-world pauses scale with source/recovery and retained candidate size;
no online work or hardware power-loss certification. Small or active-only
unsealed stores below conjunctive thresholds can retain terminals indefinitely;
finite retention is eligibility, not an exact deletion deadline. Hour-bucket
estimation may add up to one hour delay and discarded summaries only defer more.
Restart deliberately extends cooldown. Insufficient disk space preserves source
and requires operator capacity management; it never deletes source to create
headroom. Logging uses structured Logger metadata, not a new telemetry dependency.
Measured finite workloads do not prove universal RSS/disk-allocation peaks or
application callback drain latency. Older bounded-unaware binaries can fail closed.

All mandatory Phase-C implementation and qualification gates passed. No
unresolved acceptance blocker. Frozen contracts/fixtures and native source are
unchanged except the explicitly approved MANIFEST Value amendment and new C
fixtures. No post-Phase-C feature was added.

PHASE C COMPLETE
