# Phase 6 implementation and production qualification report

Status: **Phase 6 implementation and automated qualification GREEN; R5 release
exit NOT YET APPROVED.** All authorized implementation and qualification work is
complete. The signed measured-profile approval, license and actual release version
remain human release gates under roadmap §8.10. This report does not declare a
production release approved, tagged or published.

## Authority and phase checkpoint

Phase 6 follows the accelerated roadmap §8, approved R1–R4, immutable Event v1
appendix and frozen Phase 1–3 physical/durability/recovery contracts. Phase 5
crossed its mandatory checkpoint only after full green acceptance and the
completed [Phase 5 implementation report](phase-5-implementation-report.md).
That report records the once-only Phase 5 10,000-job reconstruction, unchanged
fixtures/contracts and legitimate storage-scale deferral. No Phase 6 semantic
shortcut was used to cross Phase 5.

Working baseline HEAD remains `e1e0fe3c8b1e29ff0dccf6a053fcff1504a738ed`.
No commit, tag, published package or release was created. Local disposable
consuming release artifacts are qualification evidence only.

## Implemented scope

- Volatile `pause_queue`, `resume_queue`, drain and explicit stop/restart APIs.
  Drain closes insert/claim admission, preserves queued work and waits for both
  durable settlement/projection and known local task death; timeout never resumes.
- A separately bounded metadata-only lifecycle permit remains usable under client
  saturation. Explicit replacement keeps the original host-supervised root while
  retiring old Engine/runtime/Writer/capabilities/ETS and local task lease. Fresh
  recovery owns its helper/flock continuously through activation and live work.
- Receipt-based canonical byte/segment/retained-definition counters, operational
  history/segment caps and conservative reserved active-outcome capacity. No
  added per-insert capacity scans; existing rotation validation remains unchanged.
  No eviction, storage mutation protocol or format change.
- Existing-only full physical/semantic offline diagnosis and initialize-only Mix
  wrappers. No activation/recovery ticket, repair command or arbitrary offsets.
- Exclusive whole-store cold copy/restore with external catalogs, strict copied-file,
  directory and ancestor sync, no-replace publication, bounded enumeration/reads,
  alias/link/FIFO refusal and evidence-preserving failures.
- Source packaging, detached consuming Mix application/built release verification,
  manual pinned CI qualification and build-time-only C11/native requirements.
- Dedicated lifecycle/scheduling/organic-rotation/compact-topology/reserve benchmark
  harness and measured-profile, operations, compatibility, restore and package docs.

No Phase 11 snapshot/retention/compaction, Phase 12 orchestration/uniqueness,
automatic torn-tail repair, distributed execution, exactly-once effects, new
storage formats, Event changes, manifests, group commit or CRC optimization.

## Verification ledger

The final integrated ordinary, platform, sanitizer, detached-package, deferred
scale and benchmark gates are green. Commands below exited zero unless an initial
environment restriction is explicitly recorded. No source changes followed the
final integrated runs; only reports, documentation and measurement artifacts were
finalized.

| Final gate | Result |
| --- | --- |
| macOS ordinary | 551 passed (19 properties, 532 tests), 16 skips; seed 686756; 54.5 s |
| Linux/Btrfs ordinary | 562 passed (19 properties, 543 tests), 5 skips; seed 811016; 50.6 s |
| macOS ASan/UBSan full ordinary | 551 passed (19 properties, 532 tests), 16 skips; seed 738342; 79.7 s; no sanitizer findings |
| Linux/Btrfs ASan/UBSan full ordinary | 562 passed (19 properties, 543 tests), 5 skips; seed 979374; 54.0 s; no sanitizer findings |
| macOS detached consuming production release | 1 passed; seed 205502; 4.7 s; native Mach-O arm64, no runtime Mix/compiler/checkout/test providers/fault API |
| Linux detached consuming production release | 1 passed; seed 614908; 7.0 s; native ELF aarch64; strict-sync initialize/execute/recover lifecycle passed |
| Deferred scale: 10,000 jobs, exact 1 GiB, 300 segments | 4 passed; seed 227930; 354.0 s; scope qualification below |
| Final formatting / warnings-as-errors compile / whitespace check | All passed; development and production compilation passed |
| Application startup | Storage-free root has no children; status is bounded `:unavailable` |
| Dedicated production-build benchmarks | Seven runs passed, including verified 1 GiB memory-capped 10,000-job repeat |

The ordinary inventory is **567 cases**, 83 more than the Phase 5 checkpoint.
macOS skips are nine pre-existing strict-sync cases, two strict restore-sync cases,
four opt-in scale cases and one opt-in package case. Linux skips are just those
four scale cases and one package case; both opt-in suites passed separately.
macOS strict durability is unsupported, not a passing production mode.
Platform/opt-in skips are not passes.
The macOS package command initially could not acquire Mix's localhost lock under
the sandbox (`:eperm`); the exact same command passed with approved escalation.
No test was weakened or skipped to bypass that environment restriction.
Missing-license warnings from local Hex packaging are explicit publication
blockers, not Elixir compiler warnings or an invented license decision.

Exact final commands:

```sh
# ordinary_macos
mix test --warnings-as-errors

# ordinary_linux
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 elixir:1.20.2 mix test --warnings-as-errors

# sanitized_macos
TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized mix test --warnings-as-errors

# sanitized_linux
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/sanitized-phase6 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_NATIVE_SANITIZE=1 elixir:1.20.2 mix test --warnings-as-errors

# package_macos_escalated
TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors

# package_linux
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_PACKAGE_TEST=1 elixir:1.20.2 mix test test/tay/system/package_test.exs --warnings-as-errors

# scale_linux
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_LARGE_SEGMENT_TEST=1 -e TAY_LARGE_RECOVERY_TEST=1 elixir:1.20.2 mix test test/tay/storage/segment_large_test.exs test/tay/storage/recovery_large_test.exs test/tay/engine/large_recovery_test.exs --warnings-as-errors
```

Focused implementation checks below are supplementary, not substitutes for the
final integrated gate.

| Exact command | Focused result |
| --- | --- |
| `mix test test/tay/execution/operations_test.exs test/tay/execution/control_test.exs test/tay/execution/fault_test.exs test/tay/execution/model_test.exs test/tay/engine/capacity_test.exs test/tay/engine/config_test.exs --warnings-as-errors` | 65 passed (1 property, 64 tests), 1 opt-in skip; seed 73826; 13.1 s |
| `mix test test/tay/execution/operations_test.exs --warnings-as-errors` | 8 passed; seed 844114; 0.6 s |
| `mix test test/tay/execution/operations_test.exs test/tay/execution/operations_fault_test.exs test/tay/engine/operational_capacity_test.exs --warnings-as-errors` | 16 passed; seed 157182; 1.5 s |
| `mix test test/tay/execution/restart_test.exs --warnings-as-errors` | Final lifecycle slice: 13 passed; seed 63319; 5.3 s; exact runtime/fence death-ordering tests included |
| `mix test test/tay/system/diagnostics_test.exs test/tay/system/restore_test.exs --warnings-as-errors` | 23 passed, 2 Linux-only skips; seed 272570; 8.4 s |
| `mix test test/tay/qualification/benchmark_test.exs --warnings-as-errors` | 7 passed; seed 862497; 4.5 s; compact focused cases, no scale qualification claim |
| `TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors` | Earlier package slice: 1 passed; seed 910489; 3.9 s; superseded by final package gate above |

Focused formatter, `mix compile --warnings-as-errors` and `git diff --check` passed
after slices. During parallel integration, a clean Linux diagnostic build initially
reported the not-yet-landed `Operations` module; those expected integration warnings
were resolved before later clean focused compilation. New-test setup assumptions
were corrected without changing historical assertions: fake monotonic timeout
tests must deliver the relay timer message, detached roots require explicit test
cleanup, same-ID reconciliation remains allowed while draining, and interrupted
retry obeys persisted due time before callback reentry. No contract was weakened.

Focused Linux diagnostics/restore command:

```sh
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/restore-slice -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 elixir:1.20.2 mix test test/tay/system/diagnostics_test.exs test/tay/system/restore_test.exs --warnings-as-errors
```

Result: 25 passed, seed 675394, 1.0 s, no warnings. Actual volume revalidated:

```sh
docker volume inspect tay-phase2-20260912-validation
docker run --rm --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data elixir:1.20.2 stat -f -c '%T' /tay-data
```

Local driver; actual filesystem `btrfs`. This is software qualification in a
Linux container/VM, not certification of physical hardware power loss.

## Fault, lifecycle and resource coverage

Added coverage includes pause barrier/reply loss; drain timeout, multiple
waiters and saturated admission; durable outcome before delayed task termination;
stalled post-append/pre-projection finish; native finish error/short write/helper
loss during drain; explicit fresh restart; force-stop/late results; driver death;
old-generation revision/capability rejection; lowered admission caps; active
finish reserves; exact sealed-successor accounting; same-ID reconciliation under
lower caps; whole-store restore, missing lock/STORE/history, unsupported schemas,
older-backup RPO, corrupted catalogs, sync failure/order, no-replace publication,
bounded enumeration/reads, source aliases, symlinks/hardlinks and FIFO refusal.

Independent review identified and verified fixes for three new Phase 6 issues:
the final restart reply now verifies exact new runtime/fence health, not only
queued ready state and Engine/Writer liveness; diagnostic waits chunk local BEAM
timers without narrowing approved absolute recovery deadlines; and a token-scoped
Engine barrier prevents queued cancel/retry appends after lifecycle drain ACK but
before Guardian closes the group. Deterministic adverse-ordering/huge-deadline
regressions pass. Focused combined operation faults/restart/diagnostics: 26 passed,
seed 572533, 3.1 s. No frozen-contract contradiction or format change was needed.

The retained [independent adversarial review](phase-6-adversarial-review.md)
signed off the integrated fixes with no remaining correctness/data-loss blocker
under documented cooperative ownership.
This is not R5 profile approval or device certification.

The new external-oracle matrix performs actual whole-VM SIGKILL at **19 boundaries**:
3 activation, 5 insertion/reply, 5 start/release, 3 finish and 3 cancellation.
Seed and observed insertion ACKs plus bounded callback effects are fsynced outside
the Tay namespace. Exact Event participation, every observed ACK, no callback
before release and byte/namespace preservation survive locked diagnosis plus fresh
recovery. Each child has an eight-second watchdog. All 19 cases pass in both full
ordinary and sanitized suites. Focused isolated macOS run: seed 358204, 6.1 s;
Linux strict-sync run: seed 92968, 4.6 s. An initial shared-build run encountered
an ebin replacement during concurrent Mix compilation before reaching a boundary;
isolated builds eliminated this harness interference, without changing assertions
or retrying any mutation.

The 1,132-byte operational reserve per active outcome is conservative: immutable
Event v1 maximum finish payload/frame is 269/297 bytes, and cancel is 113/141.
The extra 64-byte footer and 44-byte header allow each outcome its own rotation.
Coordinate reservations remain separate. Logical reservations do not reserve real
disk blocks or guarantee progress through ENOSPC, device failure or infinite crashes.
Lowering history/segment caps can block post-activation interruption reconciliation;
raising operational budgets and fresh recovery is the supported response, not
editing or truncating physically valid history.

## Platform, scale and measured workload

The macOS development host was Darwin 25.6.0 arm64, 24 GiB RAM, ten cores,
Elixir 1.20.2 / OTP 29 / ERTS 17.0.2, on APFS. Linux qualification used
`elixir:1.20.2`, ERTS 17.0.5, aarch64 kernel
`7.0.14-orbstack-00380-ga7e0a2dc9535`, ten CPUs and
`MemTotal=12304840 kB`. The dedicated local validation volume was Btrfs, with
219 GiB total / 194 GiB free at the qualification check. Build and data volumes
were separate. These are local container/VM results, not a remotely executed CI
matrix, arbitrary Linux-filesystem qualification or hardware power-cut evidence.
The pinned manual qualification workflow was added but not remotely dispatched.

The opt-in command passed all four cases, including real 1 GiB physical traversal,
300-segment traversal and 10,000-job production candidate/index reconstruction.
The unchanged physical scale helpers explicitly use `:write` and test-only
semantic providers, even on the Linux host with `TAY_TEST_SYNC=1`: they prove
physical geometry/traversal/resource behavior, **not** 1 GiB of production Event
execution or strict-sync performance. The production Engine reconstruction case
does use the Linux strict-sync helper. The 1 GiB case explicitly uses its test
deadline of 1,800,000 ms; it is not advertised under default-profile restart time.

All seven benchmark commands ran sequentially, after storage qualification, in
separate production-build VMs against unique synthetic stores on the validated
Linux/Btrfs volume. The raw [qualification artifacts](qualification/README.md)
are retained unchanged. No storage scan was removed, format optimized, mutation
retried or deadline enlarged beyond the configured benchmark's 900,000 ms
recovery/activation defaults to produce these observations.

| Measurement | Observed result |
| --- | --- |
| Small-args joint cohort | 10,000 completed jobs, 30,000 Events, 1,105 encoded args bytes/job, four execution credits, eight offered clients, 64 admission slots, one segment / 19,385,044 canonical bytes |
| Cohort throughput and insert latency | 198.86 jobs/s; insert p50/p95/p99 19.277/25.542/28.676 ms, 10,000 samples |
| Writer receipt latency p95 / p99 | Insert 2.156/4.490 ms; start 2.125/3.693 ms; finish 2.273/4.566 ms |
| Execution timing | Start receipt → callback p99 0.312 ms; return → finish receipt p99 24.423 ms; 5,000 callbacks served per queue |
| Fresh production replay | 12.997962 s; no owner retry; 68,130,000 charged state bytes / 950,000 nodes; private ETS 15,448,760 bytes |
| Same cohort under 1 GiB container memory cap | Completed and replayed; 217.57 jobs/s, insertion p99 25.694 ms, restart 8.259914 s |
| Eight-client schedule experiment | Eight overlapping calls verified; 20 idle/20 loaded probes; p99 80 ms idle / 193 ms loaded; zero slot refusals |
| 64-client overload experiment | Only 63 calls observed overlapping, saturation flag false; 52 known pre-I/O refusals, loaded p99 1,184 ms; retained honestly, not a proven 64-client saturated profile |
| Organic rotation | 64 future-scheduled jobs, 262,081 encoded args bytes each, 16,801,848 bytes/two segments; exactly one rotation, 2.051841 s; jobs not executed |
| Compact 1/10/100-segment replay | 1,571/16,286/163,436 bytes; 9.909/8.776/69.615 ms; not filled segments |
| Outcome reserve experiment | 3,000-byte cap; new insertion refused without I/O at 1,845 bytes plus 1,132 reserved; existing execution durably finished at 2,083 bytes |

The two 10,000-job measurements establish neither indefinite retained-history
capacity nor an all-history RTO. Larger args and many compact segments were
independent experiments, not a Cartesian production maximum. One rotating
append supplies one observation, not a p95/p99 tail guarantee. Timing uses
trace instrumentation and a 50 ms wake interval rather than the 1,000 ms source
default. Full scope, counters and the **not yet approved** finite deployment
policy are in [production limits](production-limits.md).

The Python wrapper reported Linux `RUSAGE_CHILDREN` maximum RSS and CPU/wall time
for each whole command, including runtime/build/observer overhead. RSS is not the
sum of simultaneous children or a minimum Tay memory requirement; 5 ms VM memory
sampling inside the harness can miss transient peaks.

| Command cohort | Max RSS (KiB) | Whole-command wall (s) | User / system CPU (s) |
| --- | --- | --- | --- |
| lifecycle | 289,284 | 64.624925 | 18.766220 / 2.608483 |
| schedule | 150,208 | 2.338644 | 0.898437 / 0.269565 |
| rotation | 169,744 | 4.220871 | 3.862579 / 0.262525 |
| replay | 137,772 | 3.570952 | 1.755510 / 0.335455 |
| reserve | 131,752 | 0.690802 | 0.470048 / 0.220898 |
| schedule_8 | 146,400 | 1.186009 | 0.582375 / 0.243766 |
| lifecycle_1g | 275,500 | 54.925889 | 15.047280 / 2.140822 |

The capped repeat used `--memory=1g --memory-swap=1g`; reported
`/sys/fs/cgroup/memory.max=1073741824`, completed its JSON and exited zero.
No OOM-kill interrupted it; `memory.events` was not independently sampled.
No arbitrary application callback memory bound follows from a no-op worker.

Exact benchmark commands, all exit zero:

```sh
# benchmark_lifecycle
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 python3 -c 'import json,resource,subprocess,sys,time; start=time.monotonic(); result=subprocess.run(sys.argv[1:]); usage=resource.getrusage(resource.RUSAGE_CHILDREN); print("COMMAND_RUSAGE "+json.dumps({"max_rss_kib":usage.ru_maxrss,"user_seconds":usage.ru_utime,"system_seconds":usage.ru_stime,"wall_seconds":time.monotonic()-start}),flush=True); sys.exit(result.returncode)' mix run --no-start bench/run.exs --scenario lifecycle --mode sync --validated-filesystem --path /tay-data/phase6-final-lifecycle-20260913 --output /workspace/docs/qualification/linux-lifecycle.json --jobs 10000 --args-bytes 1024 --clients 8

# benchmark_schedule
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 python3 -c 'import json,resource,subprocess,sys,time; start=time.monotonic(); result=subprocess.run(sys.argv[1:]); usage=resource.getrusage(resource.RUSAGE_CHILDREN); print("COMMAND_RUSAGE "+json.dumps({"max_rss_kib":usage.ru_maxrss,"user_seconds":usage.ru_utime,"system_seconds":usage.ru_stime,"wall_seconds":time.monotonic()-start}),flush=True); sys.exit(result.returncode)' mix run --no-start bench/run.exs --scenario schedule --mode sync --validated-filesystem --path /tay-data/phase6-final-schedule-20260913 --output /workspace/docs/qualification/linux-schedule.json --jobs 20 --args-bytes 1024 --clients 64

# benchmark_rotation
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 python3 -c 'import json,resource,subprocess,sys,time; start=time.monotonic(); result=subprocess.run(sys.argv[1:]); usage=resource.getrusage(resource.RUSAGE_CHILDREN); print("COMMAND_RUSAGE "+json.dumps({"max_rss_kib":usage.ru_maxrss,"user_seconds":usage.ru_utime,"system_seconds":usage.ru_stime,"wall_seconds":time.monotonic()-start}),flush=True); sys.exit(result.returncode)' mix run --no-start bench/run.exs --scenario rotation --mode sync --validated-filesystem --path /tay-data/phase6-final-rotation-20260913 --output /workspace/docs/qualification/linux-rotation.json --rotation-segments 2

# benchmark_replay
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 python3 -c 'import json,resource,subprocess,sys,time; start=time.monotonic(); result=subprocess.run(sys.argv[1:]); usage=resource.getrusage(resource.RUSAGE_CHILDREN); print("COMMAND_RUSAGE "+json.dumps({"max_rss_kib":usage.ru_maxrss,"user_seconds":usage.ru_utime,"system_seconds":usage.ru_stime,"wall_seconds":time.monotonic()-start}),flush=True); sys.exit(result.returncode)' mix run --no-start bench/run.exs --scenario replay --mode sync --validated-filesystem --path /tay-data/phase6-final-replay-20260913 --output /workspace/docs/qualification/linux-replay.json --replay-segments 1,10,100 --args-bytes 1024

# benchmark_reserve
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 python3 -c 'import json,resource,subprocess,sys,time; start=time.monotonic(); result=subprocess.run(sys.argv[1:]); usage=resource.getrusage(resource.RUSAGE_CHILDREN); print("COMMAND_RUSAGE "+json.dumps({"max_rss_kib":usage.ru_maxrss,"user_seconds":usage.ru_utime,"system_seconds":usage.ru_stime,"wall_seconds":time.monotonic()-start}),flush=True); sys.exit(result.returncode)' mix run --no-start bench/run.exs --scenario reserve --mode sync --validated-filesystem --path /tay-data/phase6-final-reserve-20260913 --output /workspace/docs/qualification/linux-reserve.json

# benchmark_schedule_8
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 python3 -c 'import json,resource,subprocess,sys,time; start=time.monotonic(); result=subprocess.run(sys.argv[1:]); usage=resource.getrusage(resource.RUSAGE_CHILDREN); print("COMMAND_RUSAGE "+json.dumps({"max_rss_kib":usage.ru_maxrss,"user_seconds":usage.ru_utime,"system_seconds":usage.ru_stime,"wall_seconds":time.monotonic()-start}),flush=True); sys.exit(result.returncode)' mix run --no-start bench/run.exs --scenario schedule --mode sync --validated-filesystem --path /tay-data/phase6-final-schedule-8-20260913 --output /workspace/docs/qualification/linux-schedule-8.json --jobs 20 --args-bytes 1024 --clients 8

# benchmark_lifecycle_1g
docker run --rm --memory=1g --memory-swap=1g --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/phase6-prod -e MIX_HOME=/tay-build/mix -e MIX_ENV=prod elixir:1.20.2 python3 -c 'import json,resource,subprocess,sys,time; start=time.monotonic(); result=subprocess.run(sys.argv[1:]); usage=resource.getrusage(resource.RUSAGE_CHILDREN); print("COMMAND_RUSAGE "+json.dumps({"cgroup_memory_max":open("/sys/fs/cgroup/memory.max").read().strip(),"max_rss_kib":usage.ru_maxrss,"user_seconds":usage.ru_utime,"system_seconds":usage.ru_stime,"wall_seconds":time.monotonic()-start}),flush=True); sys.exit(result.returncode)' mix run --no-start bench/run.exs --scenario lifecycle --mode sync --validated-filesystem --path /tay-data/phase6-final-lifecycle-1g-20260913 --output /workspace/docs/qualification/linux-lifecycle-1g.json --jobs 10000 --args-bytes 1024 --clients 8
```

Artifact SHA-256 values (`shasum -a 256 docs/qualification/*.json`):

```text
85c00dde9e60e72f4e80c1a5974051b5eb368bce93997bb7cda99f848b5f4269  linux-lifecycle-1g.json
d15d131ab76b1e9c6abb1a4b6b19a4427dd08e67ea0d059dde317f864734f0f8  linux-lifecycle.json
e87ee229d428501dd02e6b4b0544fc1188056b916b309a47e155ce221754180d  linux-replay.json
7642da37c116c3c86268dc4b8be32b25034bc9577d1133302c5fc0ad98d33724  linux-reserve.json
b1fc08e9779e6be6268ebeea707e5654627b0ed84cb4b314e252ec70eda835b5  linux-rotation.json
521b2acdffe1bdbd80353d0eac3465a5d1da2a5753e96045c4e678cb8a55d0e3  linux-schedule-8.json
c46f4e21a85dcc3468aa97d04c35e7f9fe04d375943f75aa24edbaac21beb103  linux-schedule.json
```

## Frozen compatibility and files

The final read-only frozen comparison exited zero. Record/Segment/STORE codec,
Reader/Writer/Recovery/native source, Event codec, pure Transition, historical
storage/Event/Transition tests and binary fixtures are unchanged from HEAD.
No existing Phase 1–5 test assertion was deleted or weakened to make Phase 6 pass.
All 50 approved Event literal vectors and decoded-byte hashes match the approved
appendix, independently checked with Ruby rather than the implementation codec.
The aggregate SHA-256 of the 46 tracked physical fixture checksum lines is
`ecab6df7e7bd5215c1f85daee397ab484bb7a23cce90941fb9c77d28267b1004`;
the Event `SHA256SUMS` file hash is
`092abb6de9965b1077edd88e4316d89474595fb2500a0783b920ba440b3cbae0`.
These match the accepted earlier baseline. The physical aggregate includes ordered
paths/checksum text; it is not a hash of concatenated raw fixture bytes.

Exact final checks and startup commands:

```sh
# final_formatter
mix format --check-formatted

# final_compile
mix compile --warnings-as-errors

# production_compile_macos
MIX_ENV=prod mix compile --warnings-as-errors

# final_diff_check
git diff --check

# final_frozen_contracts
git diff --exit-code -- lib/tay/storage c_src lib/tay/event.ex lib/tay/event lib/tay/state/transition.ex test/fixtures test/tay/storage test/tay/event test/tay/state test/support/record_helpers.ex test/support/segment_helpers.ex test/support/native_helpers.ex test/support/recovery_helpers.ex

# final_head
git rev-parse HEAD

# application_startup_macos
mix run -e 'IO.inspect(Supervisor.which_children(Tay.Supervisor)); IO.inspect(Tay.status())'

git ls-files -z test/fixtures/storage | xargs -0 shasum -a 256 | shasum -a 256

shasum -a 256 test/fixtures/events/v1/SHA256SUMS

ruby -rdigest -e 's = File.read("docs/event-v1-contract-appendix.md"); vectors = {}; s.scan(/^#### ([EN][0-9]+)\n\n```hex\n(.*?)```/m) { |id, hex| vectors[id] = hex.gsub(/\s/, "") }; s.scan(/^\| ([VX][0-9]+)[^\n]*?\| `([0-9a-f]+)` \| `([0-9a-f]{64})` \|/) { |id, hex, hash| vectors[id] = hex }; abort "wrong count" unless vectors.size == 50; manifest = File.readlines("test/fixtures/events/v1/SHA256SUMS").to_h { |line| hash, file = line.split; [File.basename(file, ".hex"), hash] }; vectors.each { |id, hex| actual = File.read("test/fixtures/events/v1/#{id}.hex").gsub(/\s/, ""); abort id unless actual == hex && Digest::SHA256.hexdigest([actual].pack("H*")) == manifest[id] }; puts "50/50 approved literal vectors and decoded-byte SHA-256 hashes match"'
```

Startup printed `[]` and
`%{state: :unavailable, freshness: :bounded_snapshot}`: application startup is
still storage-free. Explicit Engine startup/execution/stop/recovery is covered by
the integrated suite and detached Linux consuming release, not inferred from this
foundation smoke check.

### Exact Phase 6 file inventory

Compared with the hashed, green Phase 5 checkpoint: **11 modified,
37 created, 0 deleted**. Phase 5 itself is uncommitted; its distinct
inventory and verification remain in the Phase 5 report. No commit/tag was made.
Generated build executables and disposable test stores are not source files.
Synthetic benchmark stores remain in the dedicated test volume. Successful
disposable package/consumer artifacts are cleaned unless `TAY_PACKAGE_KEEP=1`;
failed artifacts are retained for diagnosis.

Modified:

- `README.md`
- `TAY_PLAN.md`
- `docs/architecture.md`
- `lib/tay.ex`
- `lib/tay/engine.ex`
- `lib/tay/engine/admission.ex`
- `lib/tay/engine/config.ex`
- `lib/tay/engine/lifecycle.ex`
- `lib/tay/engine/supervisor.ex`
- `lib/tay/execution/local_fence.ex`
- `mix.exs`

Created:

- `.github/workflows/qualification.yml`
- `bench/README.md`
- `bench/harness.exs`
- `bench/run.exs`
- `docs/compatibility.md`
- `docs/operations.md`
- `docs/packaging.md`
- `docs/phase-6-adversarial-review.md`
- `docs/phase-6-implementation-report.md`
- `docs/production-limits.md`
- `docs/qualification/README.md`
- `docs/qualification/linux-lifecycle-1g.json`
- `docs/qualification/linux-lifecycle.json`
- `docs/qualification/linux-replay.json`
- `docs/qualification/linux-reserve.json`
- `docs/qualification/linux-rotation.json`
- `docs/qualification/linux-schedule-8.json`
- `docs/qualification/linux-schedule.json`
- `docs/restore.md`
- `lib/mix/tasks/tay.storage.init.ex`
- `lib/mix/tasks/tay.storage.inspect.ex`
- `lib/tay/diagnostics.ex`
- `lib/tay/engine/operations.ex`
- `scripts/tay_cold_copy.py`
- `test/support/package_consumer/config/config.exs.template`
- `test/support/package_consumer/config/runtime.exs.template`
- `test/support/package_consumer/lib/tay_qualification.ex.template`
- `test/support/package_consumer/mix.exs.template`
- `test/tay/engine/operational_capacity_test.exs`
- `test/tay/execution/operations_fault_test.exs`
- `test/tay/execution/operations_test.exs`
- `test/tay/execution/restart_test.exs`
- `test/tay/qualification/benchmark_test.exs`
- `test/tay/system/diagnostics_test.exs`
- `test/tay/system/independent_crash_matrix_test.exs`
- `test/tay/system/package_test.exs`
- `test/tay/system/restore_test.exs`

README/architecture describe the actual APIs and ownership. TAY_PLAN's added
reconciliation makes the approved Phase 4–6 replacement of historical granular
4–10 explicit; no Phase 1–3 storage wording/bytes or approved Event appendix was
rewritten. The operations and limits documents distinguish configuration policy
from historical validity and measured capacity.

### Design deviations and correctness disposition

No frozen-contract deviation, automatic repair, alternate Event state machine,
native mutation protocol change or unresolved correctness/race regression remains.
Implementation refinements are the original-root-preserving lifecycle driver,
one separately bounded control slot and optional receipt-accounted capacity caps;
they implement the approved ownership/control/reserve boundaries. Their source
defaults are not newly approved production limits. The three independently found
Phase 6 races/domain issues above were fixed and regression-tested before the
final ordinary/sanitized/package/scale qualification.

## Release limitations and remaining gate

Consult [production limits](production-limits.md), [operations](operations.md),
[compatibility](compatibility.md), [restore](restore.md) and [packaging](packaging.md).
Only measured, deadline-conforming profiles may be proposed for R5. Sampled VM
memory is not a proven maximum RSS; compact 100-segment topology is not 100 full
segments; one rotation sample is not a tail-latency guarantee. Process/syscall
faults do not prove real-device power-loss behavior. macOS write mode is development
only; unvalidated/network filesystems and relaxed production durability remain
unsupported. Incomplete/corrupt/unsupported history stays fail-closed and untouched.

Known operational boundaries include plaintext payloads, trusted embedding code,
unlinked callback children/external effects outside local fencing, non-preemptible
native worker calls potentially preventing proven death, retained-history growth,
no live backup and explicit older-backup RPO. R5 profile approval, license selection
and the actual release version remain unresolved human release decisions. The
package remains `0.1.0-dev` with no invented license. Publication/tagging additionally
requires explicit authority. Thus the implementation/automated qualification work
is complete, but the roadmap's signed first-production release exit is not claimed.
No further implementation phase, commit, tag or publication was started.
