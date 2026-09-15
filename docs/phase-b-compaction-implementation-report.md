# Store-v2 compaction Phase B implementation report

Status: **PHASE B COMPLETE — qualified 2026-09-15**.
The normative design is `docs/storage-compaction-rfc.md`. Phase A remains
accepted. Phase C, automatic policy, retention defaults and online compaction
are not included. This report replaces the contradictory historical checkpoints.

## State present at continuation

Commit `4ce1392` already contained sole-Writer/native ownership, manual
`Tay.compact/1` Lifecycle admission/permit/drain/restart integration, streaming
sealed-base construction, independent candidate replay and semantic comparison,
manifest/CURRENT publication, mutable-tail V2 writes and locked startup recovery,
epoch-scoped revision validation, first-adoption rollback intent, deferred
predecessor reclamation/startup retry and lost-CURRENT-reply reconciliation.
These are implemented, not outstanding implementation items.

The resumed worktree also already contained adversarial qualification changes:
per-unlink/per-directory-sync reclamation faults; a widened test-only fault-site
field for sites above 255; whole-VM SIGKILL tests; stricter epoch/segment topology;
admission-bound/corruption/lock/frozen-view tests; bounded reacquisition after
closing the old helper; controlled Lifecycle error recovery; and benchmark
untrace race handling. Those existing changes were preserved.

Frozen Record/Segment/STORE/Event V1 codecs and fixtures, released V2 frames,
authority layouts and the RFC were not changed in this qualification continuation.

## Qualification fixes in this continuation

* `lib/tay/storage/native.ex`: expose owner-local knowledge of explicitly closed
  helper Ports. It uses the existing private process-dictionary close tombstone;
  it does not grant filesystem or mutation authority.
* `lib/tay/storage/writer.ex`: recognize delayed exit notifications from failed
  inspection acquisitions deliberately closed by this same owner. During
  lost-reply reconciliation, a `store_busy` attempt starts and closes a helper;
  its delayed exit previously caused `:unexpected_port` after a later successful
  acquisition. Current-helper exits still poison; unmanaged Ports still fail
  closed. No publication or mutation retry was added.
* `test/tay/engine/compaction_test.exs`: deterministic closed-failed-acquisition
  regression and bounded Engine/Writer exit diagnostics for lost-reply failures.
  Durable state/definition is compared across compaction. The first draft of the
  new regression incorrectly expected `:scheduled` for an immediately available
  job; the corrected assertion compares actual pre/post state instead.
  Adds many-segment end-to-end manual-call timing. Direct interpolation of
  numeric map fields initially triggered an Elixir struct-comparison type warning;
  printing a selected statistics map resolved the proven logging/type-inference
  issue without suppressing warnings or changing validation assertions.
* `test/tay/system/package_test.exs`: include `id` in the deployed release's
  restricted runtime utility PATH. Automatic socket discovery needs UID/group
  inspection. Compiler, Mix and system Erlang/Elixir remain excluded.
* This report: reconciled current state and qualification evidence.

Temporary Lifecycle diagnostic logging was removed; no diagnostic output remains
in production. No C change was necessary in this final qualification continuation.
The existing C changes nonetheless require the final sanitizer gate below.

## Required before Phase B can pass

All mandatory Phase-B implementation and qualification gates have passed.
The final production source has passed ordinary and sanitized macOS and
Linux/Btrfs strict-sync suites, production compilation, fixture/conformance,
focused fault/crash/authority/reclamation tests, large storage/recovery and
detached release qualification. The accepted 10,000-job measurements are retained
for the unchanged candidate-construction path. There are no unresolved blockers.

## Commands and results

All test commands use `--warnings-as-errors`. Counts include properties where
ExUnit reports them separately. Deliberately faulted helper/Writer shutdown logs
are expected; an assertion failure is never counted as a pass.

### macOS arm64

* `mix format --check-formatted`: passed, including after the final fix.
* `mix compile --warnings-as-errors`: passed after the final fix.
* `MIX_ENV=prod mix compile --warnings-as-errors`: passed after final source fix.
* `mix test --warnings-as-errors`: 622 passed (22 properties, 600 tests),
  14 gated skips, seed 312675, 82.8 s before the final Port fix. Post-fix run:
  623 passed (22 properties, 601 tests), 14 skips, seed 684930, 87.5 s.
  Final serialized `mix test --warnings-as-errors --seed 418721` after the
  measurement-only logging correction: **623 passed** (22 properties, 601
  tests), 14 skips, 75.1 s.
  A concurrent ordinary/sanitized run at seed 418721 passed 619/623 and failed
  four benchmark startup/trace assertions: the two VMs shared the per-UID
  automatic executor socket. Engine listener startup failed at `start_controls/1`;
  later trace calls saw the already-dead Engine. The same ordinary seed is being
  rerun alone and passed, without hiding startup failures or weakening assertions.
* Focused command: `mix test test/tay/storage/v2_authority_test.exs
  test/tay/storage/v2_epoch_test.exs test/tay/storage/v2_phase_a_test.exs
  test/tay/storage/v2_refusal_test.exs test/tay/storage/v2_fault_matrix_test.exs
  test/tay/storage/v2_vm_crash_test.exs test/tay/storage/v2_native_test.exs
  test/tay/storage/record_fixture_test.exs
  test/tay/storage/v2_v1_migration_test.exs --warnings-as-errors`:
  60 passed, seed 446973, 15.2 s before final Port fix. Final command adds
  `test/tay/engine/compaction_test.exs`: 67 passed, seed 699483, 36.1 s.
  An earlier focused invocation named two nonexistent paths; its 48 actual
  executed tests passed, but it is not used as fixture/publication acceptance.
* `TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs
  --warnings-as-errors`: 1 passed, seed 513934, 6.3 s; detached compiler-free
  arm64 Mach-O release reported `TAY_PACKAGE_RELEASE_OK`. Final rerun:
  1 passed, seed 258632, 8.4 s.
* Explicit frozen V1/V2 conformance command: `mix test
  test/tay/event/codec_test.exs test/tay/storage/record_fixture_test.exs
  test/tay/storage/segment_codec_test.exs test/tay/storage/segment_parser_test.exs
  test/tay/storage/segment_discovery_test.exs
  test/tay/storage/v2_phase_a_test.exs --warnings-as-errors`: 60 passed
  (3 properties, 57 tests), seed 311517, 0.4 s.
* `TAY_LARGE_SEGMENT_TEST=1 TAY_LARGE_RECOVERY_TEST=1 mix test
  test/tay/storage/segment_large_test.exs
  test/tay/storage/recovery_large_test.exs --warnings-as-errors`:
  3 passed, seed 155693, 452.5 s. Includes exact 1 GiB segment geometry,
  actual 1 GiB native replay/activation with bounded reads and constant-size
  reducer candidate, and 300-segment retryable-budget recovery.

### ASan/UBSan

* `TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized-v2 mix test
  --warnings-as-errors`: recorded prior run 621/622 passed, 14 skips,
  seed 54773, 109.6 s. Same seed reproduced lost-reply `generation_lost`.
  This exposed the failed-acquisition Port race; no sanitizer diagnostic was
  suppressed. A timing-changing diagnostic run passed 622/622 but is not the
  final acceptance run.
* `TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized-v2 mix test
  test/tay/engine/compaction_test.exs --warnings-as-errors
  --repeat-until-failure 20`: all 21 runs of 6 tests passed before the final fix.
  Focused repetition did not reliably expose the full-suite race.
* Final `TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized-v2 mix test
  --warnings-as-errors --seed 54773`: 623 passed (22 properties, 601 tests),
  14 skips, 124.0 s after final source fix/regression. Final rerun after
  measurement-only logging correction: **623 passed** (22 properties, 601 tests),
  14 skips, seed 54773, 115.7 s; no ASan/UBSan findings.
  Native compiler uses `-fsanitize=address,undefined`, frame pointers, debug info,
  `-Wall -Wextra -Werror -Wformat=2` for both ordinary and fault-enabled helpers.

### Linux/Btrfs strict `:sync`

Local Docker `elixir:1.20.2` (OTP 29, Linux arm64) mirrors the manual workflow
in `.github/workflows/qualification.yml`: disposable 8 GiB loopback Btrfs,
`stat -f -c %T` verified `btrfs`, unprivileged user, `TAY_TEST_SYNC=1`,
`TAY_TEST_DATA_ROOT=/mnt/tay-btrfs/data`, `ERL_FLAGS='+S 4:4 +A 4'`.
Source is copied from a read-only host mount to a writable disposable checkout.
Only the disposable container filesystem is modified.

Final post-source-fix Docker command (line breaks only added for readability):

```sh
docker run --rm --privileged \
  --mount type=bind,src=/Users/snake/projects/tay,dst=/work,readonly \
  elixir:1.20.2 sh -lc 'set -eu;
  apt-get update -qq;
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq btrfs-progs >/dev/null;
  truncate -s 8G /tmp/tay-qualification.img;
  mkfs.btrfs -q /tmp/tay-qualification.img;
  mkdir /mnt/tay-btrfs;
  mount -o loop /tmp/tay-qualification.img /mnt/tay-btrfs;
  mkdir /mnt/tay-btrfs/data /tmp/tay-checkout;
  test "$(stat -f -c %T /mnt/tay-btrfs)" = btrfs;
  tar -C /work -cf - lib c_src test bench scripts docs config clients mix.exs mix.lock .formatter.exs LICENSE CHANGELOG.md README.md .github deps | tar -C /tmp/tay-checkout -xf -;
  chown -R nobody:nogroup /tmp/tay-checkout /mnt/tay-btrfs/data;
  runuser -u nobody -- env MIX_HOME=/tmp/tay-mix HEX_HOME=/tmp/tay-hex TAY_TEST_DATA_ROOT=/mnt/tay-btrfs/data TAY_TEST_SYNC=1 MIX_BUILD_PATH=/tmp/tay-checkout/_build ERL_FLAGS="+S 4:4 +A 4" sh -lc "set -eu;
  cd /tmp/tay-checkout;
  mix local.hex --force;
  mix format --check-formatted;
  mix compile --warnings-as-errors;
  mix test --warnings-as-errors;
  MIX_ENV=prod mix compile --warnings-as-errors;
  TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors;
  TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=/tmp/tay-checkout/_build/sanitized mix test --warnings-as-errors"'
```

The separate large-run container used the same setup and `clients/` copy,
then package, the three-test large-storage command listed below, and full
sanitizers. Earlier setup attempts and their failures are retained below.

First ordinary attempt ran as root with a read-only checkout: 628/631 passed;
two ExUnit tmp-dir failures and a root-bypassed permission test were environment
errors. Second attempt omitted `clients/`: 628/631 passed, three Python import
failures. Including `clients/` and running unprivileged resolved these without
changing tests: **631 passed (22 properties, 609 tests), 5 skips**, seed 71397,
77.6 s. Format/development/prod compile passed. Linux has extra strict-sync
tests enabled, explaining the count difference from macOS.

Detached release initially failed because its test runtime PATH omitted `id`.
After the harness correction, `TAY_PACKAGE_TEST=1 mix test
test/tay/system/package_test.exs --warnings-as-errors`: **1 passed**, seed 36480,
4.2 s. Deployed ELF arm64 release printed both `TAY_PACKAGE_SYNC_LIFECYCLE_OK`
and `TAY_PACKAGE_RELEASE_OK`.

Linux 1 GiB command: `TAY_LARGE_SEGMENT_TEST=1 TAY_LARGE_RECOVERY_TEST=1
mix test test/tay/storage/segment_large_test.exs
test/tay/storage/recovery_large_test.exs --warnings-as-errors`: **3 passed**,
seed 313447, 378.8 s, including actual strict-sync 1 GiB recovery/activation.
The Port-notification fix does not change the successful read/replay/activation
path measured by these scale tests.

Final post-source-fix ordinary run: **632 passed** (22 properties, 610 tests),
5 skips, seed 682682, 75.5 s. Format/development/prod compile passed.
Final detached release: **1 passed**, seed 423009, 4.2 s, both release markers.
Final `TAY_NATIVE_SANITIZE=1
MIX_BUILD_PATH=/tmp/tay-checkout/_build/sanitized mix test --warnings-as-errors`:
**632 passed** (22 properties, 610 tests), 5 skips, seed 374134, 86.0 s;
no ASan/UBSan findings. This snapshot precedes only test measurement logging,
not any subsequent production source change. A second large-run container's
supplementary pre-Port-fix sanitizer run passed **631** (22 properties, 609
tests), 5 skips, seed 682782, 79.5 s.

## Fault sites and crash evidence

`v2_fault_matrix_test.exs` exercises candidate creation; base write/seal/sync;
empty tail; manifest write/sync; independent validation; epoch rename and both
directory syncs; adoption intent/move/marker/rollback; staged CURRENT write/sync;
atomic CURRENT replacement/root sync/post-read; first mutation/tail rotation;
reclamation and post-publication errors. Error, short-write/ENOSPC and helper
crash scenarios remain fail closed, without repair/truncation/padding.

Reclamation sites 258–269 individually cover segment unlink/parent sync,
segments-dir unlink/epoch sync, manifest unlink/parent sync, epoch unlink/epochs
sync, ADOPTION unlink/root sync, rollback marker and intent unlink. Tests inject
errors and helper crashes and restart/retry partial V2 A→B cleanup with nonempty
semantic state, proving B unchanged and A deleted. CURRENT is never reclaimed.
Post-CURRENT failures cannot restore old authority. First-adoption rollback is
tested before CURRENT, preserving recoverable V1 authority under the same lock.

Whole-VM suite has two tests covering six publication/adoption sites and four
V2→V2 reclamation sites with independent child VM SIGKILL, ARMED evidence,
single-authority restart and resumed predecessor deletion. Other ordinary
recovery/execution/independent-crash matrices run in the full suite.
Cross-process V2 lock contention and source frozen-tail modification refusal
are in `v2_native_test.exs`. Corruption coverage includes CURRENT/marker/manifest,
digest/inventory, rechecksummed snapshot ordering/profile, tail sequence/mutation,
extra epoch/segment entries and unexpected root directories. Refusal preserves
bytes. Admission tests cover empty/nonempty stores, minimum-size rotations and
900 kB generated snapshots: actual candidate files equal reported bytes and are
never larger than the admitted bound. Source is not deleted for headroom.

## Retained measurements and limitations

Accepted 10,000-job reconstruction/compaction/recovery result already obtained
for the candidate-construction implementation is retained, not unnecessarily
rerun. Final changes affect only closed failed helper notifications and the
package-test utility PATH; construction/replay/encoding and measurement code
are unchanged.

* Source: 4,320,152 bytes.
* Candidate: 5,750,806 bytes; admitted bound: 6,799,240 bytes.
* Candidate/source: 1.33116×.
* Logical peak source-plus-candidate/source: 2.33116×; physical allocation peak
  was not sampled (filesystem metadata, staged files and allocation are extra).
* Recorded compaction pause: 15,124 ms; repeat large-suite run: 16,908 ms.
  This is Publisher construction/publication time, not full admission/drain/
  restart latency. It must not be labelled an end-to-end stop-the-world maximum.
* Writer-process sampled peak: 34,387,032 bytes, not total VM/native/RSS peak.
* Reclaimed: 4,320,152 bytes.

These finite workloads are not a universal estimator/capacity or hardware
power-loss certificate. Production streams one Record at a time and never
calls the pure whole-store in-memory Epoch builder; recovered semantic indexes
and canonical ordering remain bounded by configured state limits. Realistic
300-source-segment manual compaction/restart is included in the Engine suite.

Final focused 300-source-segment measurement: source 162,044 bytes, candidate
193,937 bytes, admitted bound 1,298,284 bytes, candidate/source 1.19682×,
logical source-plus-candidate/source 2.19682×; Publisher pause 713 ms;
end-to-end `Tay.compact/1` call including admission/drain/recovery restart
2,016 ms; sampled Writer peak 3,147,520 bytes; reclaimed 162,044 bytes.
This quiescent retained-history run has no outstanding worker execution to
drain; it is not a bound on a busy worker's drain latency.

The final serialized ordinary many-segment run measured Publisher pause 622 ms
and manual-call pause 1,759 ms, with the same byte counts and sampled Writer
peak. The variation across these runs is retained rather than presenting one
pause measurement as a worst-case guarantee.

Linux full suites precede only the macOS-qualified measurement logging addition;
their production code and all semantic safety assertions match the final state.
Large tests are not rerun for this output-only test change or the notification-only
fix: no read bounds, encoders, replay reducers or candidate construction changed.

Unresolved blockers: **none**. Known limitations are the explicit measurement
scope, finite-workload evidence and absence of hardware power-loss certification
described above. Phase C has not begun.
