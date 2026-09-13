# Pre-release hardening report

Historical audit recorded before the Elastic-2.0, v0.5.0 and constrained-R5
decisions. For current release status see [production limits](production-limits.md)
and the final release-readiness report.

Date: 2026-09-13. Base HEAD: `0c4461e98b067933cb0c9308d9b54436073554a2` (`main`). No commit, tag, publication, or release was made.

## Verdict

The reviewed, narrowly scoped source cleanup passed all run qualification checks. No Record v1, Segment/STORE v1, Event v1, durability, recovery, or execution contract changed. This is evidence for a *constrained pre-1.0 public release*, not a claim of general production readiness. Publication remains blocked on an approved license/copyright owner, release version/tag, and human acceptance of the finite R5 operating profile and limitations below.

The audit found no demonstrated correctness defect or data-loss mechanism that requires changing a frozen contract. The remaining standalone Dialyzer warnings were classified, not suppressed; an ElixirLS Problems count is not independently reproducible as a single authoritative number.

## Audit before edits

I read `TAY_PLAN.md`, the applicable Phase 1–3 RFCs, Event v1 appendix, accelerated roadmap, Phase 5/6 reports, production limits, operations, compatibility, packaging/qualification material, and the relevant source/tests. I inventoried the repository and reviewed the critical Engine → admission → Writer/native ownership, Event codec/replay/projection, execution/operations, packaging and native build boundaries. Initial worktree was clean. The review identified:

- Large Engine, Writer, Reader and lifecycle modules, but splitting them immediately would move ownership/error boundaries without a demonstrated correctness gain. Deferred.
- Repeated validation at API and storage boundaries, intentionally enforcing different trust domains. No deduplication attempted.
- A Mix compiler defined in `mix.exs`: this is a bootstrap mechanism because Mix evaluates `mix.exs` before it can invoke the custom compiler. The editor's long-lived BEAM module-redefinition warning does not occur in clean `mix compile`; moving it requires a separately qualified bootstrap design. Left unchanged.
- Compile-time test-environment branches in Engine configuration and Operations that standalone Dialyzer treated as impossible runtime patterns. These were the only low-risk warning fixes approved for this pass.
- Defensive `Supervisor.terminate_child/2` handling and bounded decoder nonlocal exits are intentional and should not be deleted or weakened to silence analysis.
- Historical RFC wording describing earlier approval gates is historical context, not a current source of authority. No RFC or frozen contract edited.

## Changes made

| File | Exact change | Contract effect |
| --- | --- | --- |
| `lib/tay/engine/config.ex` | Select test-only option/clock/storage helpers and production durability predicate at module compilation, rather than matching literal `Mix.env()` outcomes inside ordinary function bodies. | Same accepted options, defaults, test hooks and `:prod` sync requirement. No persisted or runtime protocol change. |
| `lib/tay/engine/operations.ex` | Move the test-only pre-result hook behind a module-scope compile-time branch; retain the hook call at the same execution point and retain its exception path. | No operational state or reply-order change. |
| `lib/tay.ex` | Replace phase-by-phase top-level module prose with current Phase 6 behavior, explicit at-least-once effects, fail-closed recovery and unknown-outcome caveats. | Documentation only. |
| `docs/pre-release-hardening-report.md` | This audit/qualification and release-decision record. | Documentation only. |

There were no changes to `mix.exs`, tests, production fixtures, `c_src`, Record/Segment/STORE code, Event v1 codec/schema, state transition code, or Phase 11/12 scope.

## Independent static analysis

Fresh `MIX_ENV=test` and `MIX_ENV=prod` builds were compiled with `--warnings-as-errors` before the edits, then standalone Dialyzer 6.0.1 was run against the resulting BEAM files using the existing classic PLT `/private/tmp/tay-static-analysis.2p2MXj/classic.plt`. The same analysis was repeated after the edits. Dialyzer exit 2 denotes reported warnings, not a failed invocation. The expanded run enabled `-Wunmatched_returns -Werror_handling -Wunderspecs`; the full test build includes `test/support`, while source-only counts exclude it.

The final independently repeated commands were:

```sh
MIX_ENV=test MIX_BUILD_PATH=/private/tmp/tay-static-analysis.2p2MXj/build mix compile --warnings-as-errors
MIX_ENV=prod MIX_BUILD_PATH=/private/tmp/tay-static-analysis.2p2MXj/prod-build mix compile --warnings-as-errors
dialyzer --no_check_plt --plt /private/tmp/tay-static-analysis.2p2MXj/classic.plt -pa /opt/homebrew/Cellar/elixir/1.20.2/lib/elixir/lib/elixir/ebin /private/tmp/tay-static-analysis.2p2MXj/build/lib/tay/ebin --quiet
dialyzer --no_check_plt --plt /private/tmp/tay-static-analysis.2p2MXj/classic.plt -pa /opt/homebrew/Cellar/elixir/1.20.2/lib/elixir/lib/elixir/ebin /private/tmp/tay-static-analysis.2p2MXj/prod-build/lib/tay/ebin --quiet
dialyzer --no_check_plt --plt /private/tmp/tay-static-analysis.2p2MXj/classic.plt -pa /opt/homebrew/Cellar/elixir/1.20.2/lib/elixir/lib/elixir/ebin -Wunmatched_returns -Werror_handling -Wunderspecs /private/tmp/tay-static-analysis.2p2MXj/build/lib/tay/ebin --quiet
```

| Scope / warning mode | Before | After | Removed by cleanup |
| --- | ---: | ---: | ---: |
| test build, default | 15 | 10 | 5 |
| production build, default | 6 | 2 | 4 |
| test build including test support, expanded | 45 | 40 | 5 |
| test build, production library BEAMs only, expanded | 37 | 32 | 5 |

Remaining default production warnings are `lib/tay/engine/operations.ex:81` (defensive wildcard after `Supervisor.terminate_child/2`; current OTP inference covers `:ok | {:error, :not_found}`) and `lib/tay/event/value.ex:68` (`budget/1` intentionally has a bounded nonlocal failure path). The default test build has those two plus eight compile-time test-branch pattern warnings in Engine (2), Relay (1), Projection (2), Native (2) and Writer (1). The source-only expanded run adds one `Event.Value.invalid/1` intentional nonlocal-return warning, 17 ignored-return observations mostly from timer/monitor/native cleanup paths, and four broad-spec observations (`CRC32C.initial/0`; `Segment.parse/scan/reduce`). The full-test expanded run adds eight warnings in test-support helpers. Review found no warning demonstrating a reachable type error or a data-loss defect; the broad specs can be made more precise in a separate, behavior-preserving typing pass. No specs were weakened, ignores added, or warnings suppressed.

Complete location inventory of the 32 expanded production-library warnings (duplicate locations represent distinct emitted diagnostics):

| Classification | Locations | Count / reason retained |
| --- | --- | --- |
| Compile-time test-only branch | `engine.ex:1` ×2; `relay.ex:1` ×1; `projection.ex:1` ×2; `native.ex:1` ×2; `writer.ex:1` ×1 | 8. Source branches isolate test fault paths; moving additional guards now would disturb sensitive lifecycle/storage code solely to reduce noise. The production build has none of these. |
| Defensive branch | `operations.ex:81` | 1. Explicitly handles future/malformed child-termination results. |
| Intentional nonlocal failure | `value.ex:67`, `value.ex:68` | 2. Bounded validation throws are caught at the decoder boundary. |
| Ignored cleanup/monitor/timer result | `engine.ex:360`; `lifecycle.ex:504,530`; `queue.ex:33`; `relay.ex:69,104,156,183`; `native.ex:70,143,182,430`; `reader.ex:238`; `writer.ex:149,193,460,941` | 17. Reviewed call sites deliberately preserve the primary state/result; consuming return values would require a wider error-policy change. |
| Broad public/internal spec | `crc32c.ex:20`; `segment.ex:42,98,152` | 4. Declared ranges include cases not inferred by the current success typing; not an invalid runtime value or narrow spec. |

The additional eight expanded test-support warnings are `engine_helpers.ex:5` (throwing test worker) and `execution_helpers.ex:47,87,94,123,207,209,232` (test harness ignored returns). These modules are not compiled into production builds.

The example editor `false` versus `true` diagnostic is reproducible outside ElixirLS: `Mix.env() == :test` is a compile-time literal embedded in normal function bodies, and Dialyzer reports the impossible alternative match at line 1 of the compiled module. The scoped config/operations cleanup removes their contributions. ElixirLS's `Mix.Tasks.Compile.TayNative` redefinition arises when a persistent editor VM reevaluates `mix.exs`; clean test and production Mix compiles do not report it. We did not claim that every one of the approximately 97 editor Problems entries maps to a distinct Dialyzer issue or verify an exact editor-only total.

## Qualification commands and results

All commands below were run after the changes unless explicitly described as baseline. `mix` initially could not acquire its localhost compile lock in the sandbox (`:eperm`); the same fresh-build commands passed with approved elevated execution. This was a sandbox constraint, not a compile failure. All ordinary commands below exited 0.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix test test/tay/engine/config_test.exs test/tay/execution/operations_test.exs test/tay/execution/operations_fault_test.exs test/tay/execution/restart_test.exs --warnings-as-errors
mix test --warnings-as-errors
TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized mix test --warnings-as-errors
mix test test/tay/system/independent_crash_matrix_test.exs test/tay/execution/fault_test.exs test/tay/execution/operations_fault_test.exs test/tay/system/restore_test.exs --warnings-as-errors
mix test test/tay/event/codec_test.exs test/tay/event/atom_independence_test.exs test/tay/storage/record_fixture_test.exs test/tay/storage/segment_codec_test.exs --warnings-as-errors
TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors
git diff --check
git diff --exit-code -- test/fixtures lib/tay/storage c_src lib/tay/event lib/tay/event.ex lib/tay/state/transition.ex
```

Results in that order: formatting and both compiles passed; focused config/operations 29 passed; macOS ordinary suite 551 passed (19 properties + 532 tests), 16 skipped; macOS ASan/UBSan 551 passed, 16 skipped, no sanitizer report; focused crash/race/restore 85 passed, 3 skipped; focused Event/fixture 38 passed (2 properties + 36 tests); detached macOS consumer package/release 1 passed; both Git checks passed. The ordinary suites include unchanged Phase 1–6 regression, fault and fixture tests. The focused crash matrix includes 19 independently SIGKILL-tested boundaries. Seeds: 720357, 947313, 965187, 648541, 135810 and 874951 respectively.

Linux qualification used Docker `elixir:1.20.2` with a local-driver volume `tay-phase2-20260912-validation`; `docker volume inspect tay-phase2-20260912-validation` reported a local volume, and `docker run --rm --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data elixir:1.20.2 stat -f -c '%T' /tay-data` reported `btrfs`. This validates the container-visible filesystem, not power-loss behavior of the host's virtual-disk stack. The exact common prefix for the following commands was:

```sh
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/pre-release -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 elixir:1.20.2 mix test --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/pre-release-sanitized -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_NATIVE_SANITIZE=1 elixir:1.20.2 mix test --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/pre-release -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_PACKAGE_TEST=1 elixir:1.20.2 mix test test/tay/system/package_test.exs --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/pre-release -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_LARGE_SEGMENT_TEST=1 -e TAY_LARGE_RECOVERY_TEST=1 elixir:1.20.2 mix test test/tay/storage/segment_large_test.exs test/tay/storage/recovery_large_test.exs test/tay/engine/large_recovery_test.exs --warnings-as-errors
```

Results: Linux/Btrfs strict-sync ordinary suite 562 passed (19 properties + 543 tests), 5 skipped, seed 796242; Linux ASan/UBSan strict-sync 562 passed, 5 skipped, seed 333714, no sanitizer report; detached Linux consumer package/release 1 passed, seed 615288; opt-in large suite 4 passed, seed 526624, including one 10,000-job reconstruction, exact 1 GiB physical recovery and 300-segment case. The large suite took 355.3 seconds. Package tests built Mach-O and ELF aarch64 consumer native helpers respectively. Both package tests emitted the known missing-license warning; neither treated it as a compile/runtime error.

Fixture integrity checks, run separately from ordinary tests:

```sh
git ls-files -z test/fixtures/storage | xargs -0 shasum -a 256 | shasum -a 256
shasum -a 256 test/fixtures/events/v1/SHA256SUMS
ruby -rdigest -e 's = File.read("docs/event-v1-contract-appendix.md"); vectors = {}; s.scan(/^#### ([EN][0-9]+)\n\n```hex\n(.*?)```/m) { |id, hex| vectors[id] = hex.gsub(/\s/, "") }; s.scan(/^\| ([VX][0-9]+)[^\n]*?\| `([0-9a-f]+)` \| `([0-9a-f]{64})` \|/) { |id, hex, hash| vectors[id] = hex }; abort "wrong count" unless vectors.size == 50; manifest = File.readlines("test/fixtures/events/v1/SHA256SUMS").to_h { |line| hash, file = line.split; [File.basename(file, ".hex"), hash] }; vectors.each { |id, hex| actual = File.read("test/fixtures/events/v1/#{id}.hex").gsub(/\s/, ""); abort id unless actual == hex && Digest::SHA256.hexdigest([actual].pack("H*")) == manifest[id] }; puts "50/50 approved literal vectors and decoded-byte SHA-256 hashes match"'
```

Results: physical fixture aggregate `ecab6df7e7bd5215c1f85daee397ab484bb7a23cce90941fb9c77d28267b1004`; Event manifest hash `092abb6de9965b1077edd88e4316d89474595fb2500a0783b920ba440b3cbae0`. Both match the baseline. An independent literal-vector comparison also checked all **50/50** approved appendix hex payloads against fixture bytes and each decoded-byte SHA-256 entry; all matched. No frozen source or fixture file was modified.

## Capacity and benchmark rerun

All new benchmark stores were disposable, named `tay-prerel-*`, inside the validated Btrfs volume. The `bench/run.exs` scenarios were run with `MIX_ENV=prod`, `--mode sync --validated-filesystem` in the same Linux container, separately and without altering tracked `docs/qualification/*.json`. Base command (the quoted scenario arguments below were appended literally):

```sh
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/pre-release-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 mix run --no-start bench/run.exs --mode sync --validated-filesystem [scenario arguments]
```

| Scenario arguments | Result and comparison with Phase 6 baseline |
| --- | --- |
| `--scenario lifecycle --path /tay-data/tay-prerel-lifecycle-20260913-a --jobs 10000 --args-bytes 1024 --clients 8` | 10,000 completed, 19,385,044 canonical bytes, 15,448,760 ready ETS bytes, 212.53 jobs/s, insert p99 27.674 ms, restart 8.281 s. Baseline 198.86 jobs/s, 28.676 ms, 12.998 s. |
| Same lifecycle arguments with `/tay-data/tay-prerel-lifecycle-1g-20260913-a` and Docker `--memory=1g --memory-swap=1g` | Completed; 242.37 jobs/s, insert p99 26.411 ms, restart 8.234 s. Baseline capped run 217.57 jobs/s, 25.694 ms, 8.260 s. |
| `--scenario schedule --path /tay-data/tay-prerel-schedule64-20260913-a --jobs 20 --args-bytes 1024 --clients 64` | Saturated label proven by 64 overlapping calls; load schedule lag p99 992 ms, idle p99 83 ms, 33 client-slot refusals. Baseline load p99 1184 ms, idle p99 76 ms, but baseline *did not* prove its saturated label, so those load runs are not like-for-like saturation evidence. |
| `--scenario schedule --path /tay-data/tay-prerel-schedule8-20260913-a --jobs 20 --args-bytes 1024 --clients 8` | Overlap proven by 8 calls; load lag p99 206 ms, idle p99 61 ms, no slot refusals. Baseline 193/80 ms. |
| `--scenario rotation --path /tay-data/tay-prerel-rotation-20260913-a --rotation-segments 2` | Two organic segments, one measured rotation append 2.064 s, 64 inserted jobs. Baseline one measured rotation 2.052 s. One sample cannot establish tail latency. |
| `--scenario replay --path /tay-data/tay-prerel-replay-20260913-b --replay-segments 1,10,100 --args-bytes 1024` | 1/10/100 segment replay 12.237/14.779/68.211 ms; baseline 9.909/8.776/69.615 ms. These are compact topology probes, not full-segment throughput bounds. |
| `--scenario reserve --path /tay-data/tay-prerel-reserve-20260913-a` | Admission correctly refused at `max_history_bytes`, one execution settled, reserved bytes returned to zero; baseline same refusal class. This is logical headroom, not free-disk or ENOSPC proof. |

The capped repeat inserted `--memory=1g --memory-swap=1g` immediately after `docker run --rm` in the base command and used the second lifecycle path above. The replay path ending `-b` is the successfully parsed repeat; an earlier `-a` probe exited 0, but its long JSON line was truncated by the command-output capture and is not used for the reported replay metrics.

Benchmark deltas are one-run observations under instrumentation and container/host variability. They are **not** statistically established improvements or regressions. The changed source is not on the append, replay or callback hot paths.

## R5 operating profile and known limits

Recommend accepting R5 **only for an explicitly finite, single-node, Linux local-Btrfs strict-sync profile** with a 10,000-job completed-history cohort of this measured shape (1 KiB arguments, no-op callbacks, two queues, two workers/queue, eight insertion clients), around 19.4 MB canonical history and 15.45 MB ready ETS, and a separately set recovery/state budget as in `docs/production-limits.md`. Set hard `max_history_bytes`, segment, job/state, admission and deadline budgets for the actual deployment; the documented example profile has very little headroom above the completed cohort and is not an indefinite-growth default. Monitor status/headroom and plan cold-copy migration or operator intervention before caps are reached. Requalify on the target kernel, filesystem, disk and virtualisation stack; Docker Btrfs tests are not a hardware power-cut certification.

The explicit finite-policy *proposal* in `docs/production-limits.md` is `max_insert_args_bytes: 1_105`, `max_insert_payload_bytes: 2_048`, `max_jobs: 10_000`, `max_state_bytes: 80_000_000`, `max_state_nodes: 1_000_000`, `max_history_bytes: 19_390_000`, `max_segments: 5`, 64 client permits/64 MiB client-byte budget, 64 MiB rotation target, 900,000 ms recovery and activation deadlines, and the measured 50 ms wake interval. Reserve at least 1 GiB for the isolated Tay workload **plus** separately budgeted application/worker memory, and at least 1 GiB free validated local disk for store/copy/restore. These finite caps were **not jointly benchmarked**; the measured 10,000-job runs used default insertion/recovery budgets and uncapped history/segments. The history cap is only 4,956 bytes beyond the completed cohort before outcome reservations. Target-specific validation is required before treating this proposal as an approved deployment envelope. Defaults still include a 16 MiB Record physical payload hard limit, 64/100,000/16 MiB Event recovery depth/node/text+binary budgets, and 100,000 jobs / 268,435,456 charged state bytes / 2,000,000 charged nodes; such operational budgets never redefine physical or semantic validity.

The log remains authoritative; projections are rebuilt, not persisted. Recovery of a valid contiguous history is proven by tests, while torn/incomplete, corrupt, unsupported-schema or ownership-ambiguous history fails closed, preserves evidence and refuses writable activation. There is no automatic repair/truncation, snapshot/compaction, indefinite retention, distributed or exactly-once-external-effects guarantee. Completed events whose caller acknowledgement was lost still replay, and clients must reconcile same-ID insertions/unknown outcomes. Cancellation cannot undo external callback effects. Callback effects may repeat after infrastructure interruption. These are release limitations, not test failures.

This supports a narrowly labelled early public release with the above caveats and explicit operator runbooks; it does **not** support an unconstrained “production-ready for arbitrary workloads/platforms” claim. The final R5 acceptance remains a human release gate.

## License, version and release preparation: decisions requested

- **License:** Recommend Elastic-2.0 for an infrastructure library because it includes an explicit patent license and patent-litigation termination while allowing permissive use; [official license](https://www.apache.org/licenses/LICENSE-2.0). MIT is simpler but lacks explicit patent language in its [official text](https://opensource.org/license/mit). Choose the legal owner/copyright notice first, add a full `LICENSE` (and a `NOTICE` if needed), include them in the package allowlist, set `package[:licenses]` to the chosen SPDX identifier, and rerun detached package tests. No license or metadata was chosen or written in this pass. This is a release/legal decision, not legal advice.
- **Version:** `mix.exs` remains `0.1.0-dev`, yet Git tags `v0.1.0`, `v0.2.0`, `v0.3.0`, and `v0.4.0` already denote historical phase milestones; notably `v0.1.0` points to Phase 1 while its own `mix.exs` also says `0.1.0-dev`. Reusing `v0.1.0` for the first public package would be misleading or require moving a tag. Recommend **package `0.5.0` and a new `v0.5.0` tag** for the first public release, without moving earlier tags. SemVer permits unstable API evolution in `0.y.z` ([specification](https://semver.org/)). A different public tag namespace could preserve package `0.1.0`, but is less conventional and needs explicit selection. No version/tag was changed.
- **Release preparation after approval:** Add `CHANGELOG.md`/release notes distinguishing proven invariants from platform/retention limits, update README installation/version and production-profile warnings, record supported Elixir/OTP/C compiler and Linux/Btrfs assumptions, confirm source URL/owner/package files, run `mix hex.build`/detached consumer tests and a fresh-target deployment/restore drill, then request a separate publish/commit/tag action. [Hex's package metadata and publish documentation](https://hex.hexdocs.pm/Mix.Tasks.Hex.Publish.html) describes license identifiers and package file lists; these are release-review requirements for Tay. Do not advertise hardware power-loss certification, supported unknown schemas, automatic repair or exactly-once effects.
- **Suggested future commit/release wording, not executed:** `Prepare Tay 0.5.0 constrained public preview` and release title `Tay 0.5.0 — durable single-node job core (qualified Linux/Btrfs profile)`. The user must authorize the version, license and any commit, tag or publish operation.

Suggested release-note/CHANGELOG entry after those approvals: “First public Tay preview: durable Event v1 job insertion, single-node supervised execution, schedule/retry/cancellation, fail-closed recovery and explicit operational controls. Qualified for the documented finite Linux/local-Btrfs strict-sync profile. History is append-only with no automatic repair, retention or compaction; callback effects may repeat and lost replies can have unknown outcomes. macOS write mode is development-only.” The README should place that support boundary beside installation/startup instructions, link `docs/production-limits.md`, `docs/operations.md` and `docs/compatibility.md`, and say that the finite cap proposal is not yet an approved arbitrary-workload deployment envelope. Package metadata should update `version`, `licenses` and the `files` allowlist for `LICENSE`/optional `NOTICE` together, with the source URL verified by the owner.

Remaining release blockers: (1) explicit R5 acceptance of a target-specific finite operating envelope and fail-closed limitations; (2) author/copyright and Elastic-2.0 versus MIT decision, followed by license/package metadata and consumer requalification; (3) explicit package-version/tag decision in light of the existing `v0.1.0` milestone tag; (4) approved release note/README/package review and authorization for any commit, tag or publication. No qualification failure is being hidden behind these decisions.

No Phase 11 snapshots/retention/compaction, Phase 12 orchestration/uniqueness, distributed execution, or new disk/Event format work was performed.
