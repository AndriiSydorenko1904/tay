# Tay v0.5.0 final release-readiness report

Date: 2026-09-13. Base HEAD: `0c4461e98b067933cb0c9308d9b54436073554a2` on `main`. This is a **prepared public preview**, not a published release. No commit, Git tag, push, Hex publication or GitHub release was created.

## Decision and scope

**R5 is approved only for a constrained, measured and target-validated Tay v0.5.0 public-preview profile.** The reference measurements used Elixir 1.20.2 / OTP 29, a Linux aarch64 Docker/Orb VM, an explicitly checked local Btrfs volume, and strict `:sync` mode. The jointly measured cohort was 10,000 completed small-argument jobs with eight insertion callers, two queues and two execution credits each, 30,000 Events, 19,385,044 canonical bytes in one segment, 68,130,000 charged state bytes, 950,000 charged nodes and 15,448,760 ready private-ETS bytes. Phase 6 observed 198.86 jobs/s and 12.998 s fresh restart; the independent hardening rerun observed 212.53 jobs/s and 8.281 s. The 1 GiB-capped repeat completed. These are samples, not universal throughput or recovery-time guarantees.

The [R5 finite admission policy](production-limits.md) sets 1,105-byte encoded args, 2,048-byte insertion payloads, 10,000 jobs, 80,000,000 charged state bytes, 1,000,000 charged nodes, 19,390,000 canonical history bytes, five segment coordinates, 64 client permits / 64 MiB reserved client bytes, 900,000 ms recovery and activation deadlines and the measured 50 ms wake interval. The finite cap set was **not jointly benchmarked** with the cohort; it is a protective refusal policy, not a promise that arbitrary histories fitting its numeric caps match the benchmark. Its history headroom is only 4,956 bytes beyond the measured completion history before active outcome reservations. An actual deployment must validate the target kernel/filesystem/device/virtualisation stack, worker memory and workload, free-disk/backup margins, and these caps before production use. The qualification VM is a measured reference target, not hardware power-cut certification.

The release has no unrestricted production-ready, hardware-independent power-loss, exactly-once external-effect or multi-node claim. Torn/corrupt/unsupported history is fail-closed with all evidence preserved and no writable activation; there is no automatic repair or partial recovered state. Callback effects may repeat; lost replies may have unknown outcomes. Phase 11 snapshots/retention/compaction and Phase 12 orchestration/uniqueness remain deferred.

## Release artifacts and metadata

- Package/app name: `tay`; project/package version: `0.5.0`; planned, **not created** Git tag: `v0.5.0`. Earlier `v0.1.0`–`v0.4.0` tags are historical milestones.
- License: Elastic-2.0. `LICENSE` is the exact [Apache Software Foundation canonical text](https://www.apache.org/licenses/LICENSE-2.0.txt), SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`. The project uses SPDX metadata `Elastic-2.0`; no `NOTICE` content was invented.
- Description: “Public-preview single-node durable job engine with fail-closed recovery”. Source URL matches `origin`: `https://github.com/AndriiSydorenko1904/tay`. The documentation link targets the versioned `v0.5.0` Git `docs/` tree and becomes publicly resolvable after repository access and an authorized tag push. `ex_doc` / `mix docs` is not configured, so no HexDocs generation or publication is claimed. Public Hex API returned 404 for `tay` during preparation; recheck name ownership/availability before publishing.
- Package allowlist includes source, native C source, cold-copy script, `LICENSE`, `CHANGELOG.md`, README, Markdown docs and small retained qualification JSON. It excludes build output, generated native binaries, `test/`, fixture and fault providers, config, dependencies and Git metadata. The consumer recompiles its own native helper.

## Files in the worktree

| File | Release-preparation effect |
| --- | --- |
| `LICENSE` | Exact approved Elastic-2.0 text. |
| `CHANGELOG.md` | First public-preview entry, guarantees, qualification, limitations and deferrals. |
| `mix.exs` | Version, description, explicit package name, source/documentation links, SPDX license and file allowlist. Native compiler bootstrap unchanged. |
| `README.md` | Preview positioning, supported profile and safety caveats; future Hex dependency example. |
| `TAY_PLAN.md` | Top-level R5 status reconciliation only; historical plan and frozen contracts unchanged. |
| `docs/production-roadmap-rfc.md` | Current-status note above the retained historical RFC. |
| `docs/production-limits.md` | Narrow R5 approval, independent rerun evidence, finite release policy and target-validation requirement. |
| `docs/operations.md`, `docs/compatibility.md`, `docs/packaging.md` | Consistent v0.5.0/R5 release and platform/upgrade/build boundaries. |
| `docs/qualification/README.md` | Points raw measurements to the final R5 decision. |
| `docs/pre-release-hardening-report.md` | Marks its earlier open decisions as historical. |
| `docs/final-release-readiness-report.md` | This report. |
| `test/tay/system/package_test.exs` | Strengthened package assertions for LICENSE, changelog and retained measurements; optional archive-input path verifies the exact produced Hex tarball through a detached consumer on both platforms. Existing default path remains. |
| `lib/tay.ex`, `lib/tay/engine/config.ex`, `lib/tay/engine/operations.ex` | Approved prior pre-release hardening cleanup retained in the uncommitted worktree; no further production-source edit in this release-preparation pass. See [hardening report](pre-release-hardening-report.md). |

## Validation

The final release validation uses these commands (the temporary archive is a disposable local artifact, not a committed or published package):

```sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix test --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/release-r5 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 elixir:1.20.2 mix test --warnings-as-errors
HEX_OFFLINE=1 mix hex.build --output /private/tmp/tay-r5-final.GEDunX/tay-0.5.0.tar
HEX_OFFLINE=1 mix hex.build --unpack --output /private/tmp/tay-r5-final.GEDunX/unpacked
TAY_PACKAGE_ARCHIVE=/private/tmp/tay-r5-final.GEDunX/tay-0.5.0.tar TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=bind,src=/private/tmp/tay-r5-final.GEDunX,dst=/tay-package,readonly --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/release-r5 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_PACKAGE_TEST=1 -e TAY_PACKAGE_ARCHIVE=/tay-package/tay-0.5.0.tar elixir:1.20.2 mix test test/tay/system/package_test.exs --warnings-as-errors
TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors
git diff --check
git diff --exit-code -- test/fixtures lib/tay/storage c_src lib/tay/event lib/tay/event.ex lib/tay/state/transition.ex
git status --short
```

The ordinary macOS suite passed **551 cases (19 properties + 532 tests), 16 documented skips**. The Linux/Btrfs strict-sync suite passed **562 cases (19 properties + 543 tests), five documented skips**. Both detached archive-consumer paths passed one test each: Mach-O aarch64 macOS release boot/Record verification and ELF aarch64 Linux strict-sync insertion, execution, stop and fresh replay. The default source-package consumer path also passed one test. Package construction showed name/version/license/links with no missing-license warning; contents and native source/LICENSE bytes were checked independently. Formatting, test and production warning-as-error compilation, and diff checks passed. No documentation generation was run because no `mix docs` task or ExDoc dependency is configured.

The source code and byte contracts were already fully qualified in the immediately preceding [pre-release hardening pass](pre-release-hardening-report.md): macOS/Linux ordinary and ASan/UBSan suites, independent crash/race/restore, 10,000-job reconstruction, exact 1 GiB physical recovery, 300-segment traversal, fixed Event vectors and benchmarks. This release pass changed no storage/recovery/native/execution implementation and did not infer fresh hardware-power-loss or arbitrary-capacity evidence from the metadata validation.

Standalone post-version Dialyzer was rerun against fresh test and production BEAM builds using the same classic PLT and warning sets as the hardening report. It still emits **10 default test warnings and two default production warnings**, or **40** with the expanded test warning set (including eight test-support observations). Production's exact two are `lib/tay/engine/operations.ex:81` (defensive wildcard after the current OTP-inferred `Supervisor.terminate_child/2` return set) and `lib/tay/event/value.ex:68` (intentional bounded nonlocal decoder failure). Test adds `engine.ex:1` ×2, `relay.ex:1`, `projection.ex:1` ×2, `native.ex:1` ×2 and `writer.ex:1` (compile-time test-only branches). The expanded warning-by-warning inventory and acceptance reasons are in the [hardening report](pre-release-hardening-report.md). Dialyzer exit 2 denotes emitted diagnostics; no warnings were suppressed or typespecs weakened.

Physical fixture aggregate SHA-256 remains `ecab6df7e7bd5215c1f85daee397ab484bb7a23cce90941fb9c77d28267b1004`; Event v1 manifest SHA-256 remains `092abb6de9965b1077edd88e4316d89474595fb2500a0783b920ba440b3cbae0`, with all 50 approved literal vectors previously independently verified. Record v1, Segment/STORE v1, Event v1, transition implementation and native source are unchanged. No Phase 11/12 functionality was introduced. The worktree contains only the files listed above; no tag `v0.5.0` exists yet.

## Remaining human actions, not performed

1. Confirm the legal right/attribution basis for applying Elastic-2.0 to all shipped project material, review the actual target-specific R5 limits and operational caveats, and approve the release candidate.
2. Stage and commit the reviewed files; create and push `v0.5.0` only with explicit authorization. The documentation URL will then resolve for public readers if the repository is public.
3. Recheck Hex package-name availability and, separately, authorize `mix hex.publish package`. This project does not configure ExDoc/HexDocs; the versioned Git documentation link is the supported documentation destination for v0.5.0.
