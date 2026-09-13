# Production limits and qualification profile

Status: **R5 APPROVED for Tay v0.5.0's constrained public preview only.** The
measured reference target is the validated local Linux/Btrfs qualification
volume, not every Linux filesystem, device or deployment. Operators must
validate their actual target and workload before production use. This document
distinguishes immutable representability, operational configuration, observed
tests and the deliberately finite release policy. R5 does not authorize an
unrestricted production-capacity claim.

## Frozen contracts versus operational defaults

Record v1, STORE v1, Segment v1, Event schema 1 and the Phase 3 recovery protocol
are unchanged. Runtime structs are never persisted; no replay fallback, repair,
truncation, snapshots, history deletion or compaction exists in this release.

| Setting | Value / interpretation |
| --- | --- |
| Record v1 maximum payload | 16,777,216 bytes, immutable physical hard limit |
| Event type/schema capability | Types 1–6, schema exactly 1; unknown pair stops semantic recovery untouched |
| New insertion args default | 262,144 **encoded** bytes; operational, not historical validity |
| New insertion payload default | 1,048,576 encoded payload bytes; operational |
| Insertion depth/nodes | 32 / 10,000; separately checked against replay capability |
| Recovery Event depth/nodes/text+binary default | 64 / 100,000 / 16,777,216 bytes per Event |
| Retained-state default | 100,000 jobs; 268,435,456 charged bytes; 2,000,000 charged nodes |
| Startup candidate/projection accounting | Three charged state views budgeted; not an exact RSS or peak-memory guarantee |
| Client admission defaults | 64 permits; 67,108,864 total reserved byte budget; bounded before payload submission |
| Execution defaults | Due batches of 32; wake interval 1,000 ms; concurrency explicitly configured per queue |
| Rotation target default / minimum | 67,108,864 / 16,777,352 bytes; target is operational, not a physical record-validity rule |
| Recovery / activation deadline defaults | 900,000 ms each; I/O timeout 10,000 ms capped by remaining phase deadline |
| Optional history/segment admission caps | `max_history_bytes`, `max_segments`; each defaults to `:infinity`, meaning **no configured cap**, not unlimited usable capacity |

The exact normative domains and compatibility rules remain in the
[Event appendix](event-v1-contract-appendix.md),
[Phase 3 RFC](phase-3-recovery-rfc.md) and
[production roadmap](production-roadmap-rfc.md). A lower insertion limit cannot
make accepted historical bytes invalid. Higher resource budgets can permit a
new unchanged-byte recovery attempt; they cannot make corrupt data valid.

No terminal job is evicted: IDs and immutable definitions remain retained for
insertion reconciliation. History, restart time and memory therefore grow with
total retained history, not only the count of currently runnable jobs. Operators
must cap admission before actual memory/disk exhaustion. Deleting old files or
jobs is not a supported remedy.

## Outcome reserve and refusal behavior

The Engine tracks canonical segment bytes/count, retained definition bytes and
remaining sequence/segment coordinates incrementally. Status reports those
counters and reserved active-outcome bytes; it is an asynchronous bounded view,
not a backup, atomic query of storage, or an activation certificate.

An active execution reserves 1,132 history bytes: a conservative 1,024-byte
complete Event frame plus a 64-byte footer and 44-byte successor header. Every
Event v1 finish frame is at most 297 bytes; executing cancellation at most 141.
The reserve deliberately exceeds those immutable maxima. Each active outcome
also reserves a possible successor coordinate/segment, even when current space
would normally avoid rotation. Small segment caps can therefore refuse starts
before the current segment is full. This is conservative admission, not a format
change or an instruction to reduce safety checks.

New inserts/starts are rejected before I/O when their configured headroom would
consume outstanding outcome reserves. The isolated reserve scenario measures a
real refusal and subsequent durable finish. These logical reservations do not
reserve filesystem blocks, ensure free disk, prevent device/ENOSPC errors, or
support unlimited crashes. Reduced operational budgets on restart can prevent
interruption reconciliation/ready publication; restore adequate budgets and
retry a fresh generation, never edit the history.

## Measured Linux profile

Measurements used Elixir 1.20.2 / OTP 29, aarch64 Linux kernel 7.0.14 in the local
Docker/Orb VM, ERTS 17.0.5, 10 CPUs, `MemTotal=12,304,840 kB`, and an explicitly
checked local Btrfs volume (219 GiB total, 194 GiB free as reported by the host
qualification command). The macOS development host was Darwin 25.6 arm64,
24 GiB RAM, 10 cores, ERTS 17.0.2. The numbers below are Linux `:sync`, not
extrapolations from macOS `:write`. Exact commands and platform results are in the
[Phase 6 report](phase-6-implementation-report.md); raw observations are retained
under [qualification](qualification/README.md).

### Jointly measured small-argument cohort

The [10,000-job run](qualification/linux-lifecycle.json) inserted and completed
10,000 jobs through real Event v1 production recovery/execution: eight concurrent
callers, 64 admission permits / 64 MiB client-byte budget, two queues with two
execution credits each, and a bounded no-op callback. Args had a 1,024-byte text
body and 1,105 total encoded bytes; the largest immutable definition was 1,391
encoded bytes. The harness configured a 50 ms execution wake interval, not the
1,000 ms source default. Recovery/activation deadlines stayed at 900,000 ms.

| Observation | Result |
| --- | --- |
| Completed jobs / history | 10,000 / 30,000 Events / 19,385,044 canonical bytes / **one** segment |
| Definition/state charges | 13,905,000 retained definition bytes; 68,130,000 charged state bytes; 950,000 nodes |
| Throughput / bytes per completed job | 198.86 jobs/s / 1,938.5044 bytes |
| Insert ACK RTT, 10,000 samples, p50 / p95 / p99 | 19.277 / 25.542 / 28.676 ms |
| Insert / start / finish Writer receipt, p95 | 2.156 / 2.125 / 2.273 ms; 10,000 samples each |
| Insert / start / finish Writer receipt, p99 | 4.490 / 3.693 / 4.566 ms |
| Start receipt → callback, p95 / p99 | 0.180 / 0.312 ms |
| Callback return → finish receipt, p95 / p99 | 20.960 / 24.423 ms |
| Full fresh restart | 12.997962 s; no owner-release retry; within unchanged deadline |
| Private ETS after activation | 15,448,760 bytes |
| Sampled restart memory | VM total 176,968,299 bytes; Engine heap 27,999,072; Writer heap 32,787,168; VM binaries 30,484,040 |
| External command maximum RSS | 289,284 KiB; Linux `RUSAGE_CHILDREN` observation includes runtime/build, not an isolated candidate measurement |
| Queue service | 5,000 callbacks per queue |

The [independent repeat](qualification/linux-lifecycle-1g.json) used Docker
`--memory=1g --memory-swap=1g` (configured without swap), with effective cgroup
`memory.max=1,073,741,824`. It completed with exit 0 and the same 10,000-job /
19,385,044-byte cohort: 217.57 jobs/s, 25.694 ms insertion p99, 8.259914 s restart,
166,241,000-byte sampled VM peak and the same ETS size. External command maximum
RSS was 275,500 KiB; wall/user/system time was 54.925889 / 15.047280 / 2.140822 s.
The command and complete JSON succeeded; `memory.events` was not independently
sampled, so no separate OOM-event-counter claim is made. These two restart
observations are not an all-history RTO guarantee. Timings include
arity-only trace instrumentation; Writer receipt latency excludes later projection
and public reply. Five-millisecond memory sampling can miss transient peaks;
process heaps exclude shared binary backing, and VM totals include the observer.
Neither sampled peaks nor external command RSS establish a measured minimum RAM
requirement or bound arbitrary application callback memory.

The [pre-release hardening rerun](pre-release-hardening-report.md) repeated the
same 10,000-job cohort on the validated Btrfs volume: 19,385,044 canonical bytes,
212.53 jobs/s, 27.674 ms insertion p99 and 8.281 s restart. Its 1 GiB-capped
repeat completed at 242.37 jobs/s, 26.411 ms insertion p99 and 8.234 s restart.
Both retained the 15,448,760-byte ready ETS size. These one-run differences
from the Phase 6 baseline are measurement variability, not proven improvement.
The full Linux/Btrfs strict-sync and ASan/UBSan suites, detached consumer build,
10,000-job reconstruction, 1 GiB physical recovery and 300-segment test passed
again. They still do not certify host hardware power-loss behavior.

### Independent stress and operational observations

| Case / retained artifact | Actual scope and result |
| --- | --- |
| [Eight-client schedule load](qualification/linux-schedule-8.json) | 20 idle + 20 loaded probes; eight observed overlapping insertion calls, saturation flag true; idle p95/p99 78/80 ms, loaded 190/193 ms; zero client-slot refusals; 20 callbacks per queue overall |
| [64-client overload](qualification/linux-schedule.json) | 63 overlapping calls, 52 known pre-I/O refusals; saturation flag **false**; loaded p99 1,184 ms. This is retained overload evidence, not the eight-client profile or a successful 64-client saturation claim |
| [Organic rotation](qualification/linux-rotation.json) | 64 future-scheduled jobs, 262,000-byte arg text / 262,081 encoded arg bytes, 16,801,848 canonical bytes in two segments; one 2.051841 s rotating append at the unchanged 16,777,352-byte minimum target |
| [Compact replay topology](qualification/linux-replay.json) | 1 / 10 / 100 explicitly, legally rotated segments: 1,571 / 16,286 / 163,436 bytes; restart 9.909 / 8.776 / 69.615 ms |
| [Outcome reserve exhaustion](qualification/linux-reserve.json) | Configured 3,000-byte history cap; refusal at 1,845 canonical bytes with 1,132 reserved; the already-active callback then finished durably at 2,083 bytes and zero reserve |
| Index and scan trace | Main cohort: 60,000 indexed JobIndex gets and 20,099 QueueIndex selection steps; rotation: two disclosed Reader inspections / three file scans; no added per-insert capacity scan |
| Final ordinary / ASan+UBSan qualification | macOS 551 passed / 16 skipped; Linux 562 passed / five skipped, each out of 567 cases; same platform totals under sanitizers |
| Detached consuming package | One qualification case passed per platform; Linux executes/replays the production consumer, macOS verifies packaging and rejects production write mode |
| Final opt-in physical scale suite | Linux four passed in 354 s, seed 227930: 10,000-job reconstruction, 1 GiB and 300-segment cases. Frozen physical scale cases use write mode/test-only semantics: **not** a 1 GiB production Event/execution profile |

The rotation jobs were **not executed**; their large args cannot be combined with
the 10,000 completed-job cohort to advertise a Cartesian maximum. Similarly,
100 compact segments do not qualify 100 filled segments. One rotation makes
nearest-rank p95 and p99 equal its single sample, not a supported tail guarantee.
The shorter ten-segment than one-segment replay reflects ordinary small-sample
noise, not a scaling law. Fairness observations show service to both queues in
these runs, not a deadline guarantee for arbitrary worker runtimes or workloads.

## R5 finite release policy

The 10,000-job lifecycle timing runs used source defaults for insertion/candidate
budgets and `:infinity` history/segment admission caps. R5 adopts the following
**finite protective release policy**, not new source defaults or a jointly measured
configuration. It may refuse earlier than the measured uncapped run. Validate its
complete behavior on the actual deployment and workload before adoption; it is
not a throughput, recovery-time or safe-capacity promise for arbitrary histories:

| R5 release boundary | Value and purpose |
| --- | --- |
| Workload | At most the jointly measured 10,000 retained small-argument jobs, with bounded trusted callbacks; ≤ eight offered callers, two queues × two execution credits |
| Insertion caps | `max_insert_args_bytes: 1_105`, `max_insert_payload_bytes: 2_048`; measured arg shape, not arbitrary 256 KiB jobs |
| Retained-state caps | `max_jobs: 10_000`, `max_state_bytes: 80_000_000`, `max_state_nodes: 1_000_000`; operational charges, not exact RSS |
| History cap | `max_history_bytes: 19_390_000`, slightly above the measured cohort plus four conservative outcome reservations |
| Segment-coordinate allowance | `max_segments: 5`: one actual segment plus four possible reserved successors; **not** a five-full-segment measured envelope |
| Unchanged admission / timing | 64 permits, 64 MiB client-byte budget, 64 MiB rotation target, 900,000 ms recovery and activation; explicitly choose the measured 50 ms wake interval |
| Provisioning margins | At least 1 GiB reserved for the isolated Tay workload **plus** separately budgeted consuming-application/worker memory, and at least 1 GiB free validated local disk for the bounded store/copy/restore workspace; these are conservative policy margins, not measured minima or exhaustion guarantees |

Caps can refuse work early and never redefine existing-history validity. Repeated
retries, cancellations, interruptions and differing args change the relationship
between job count, records, memory and bytes. Crossing an R5 boundary requires
new target-specific measurement/review, not deleting history or assuming that
every physically valid store within one numeric cap has the measured performance.
The R5 history cap is intentionally tight: only 4,956 bytes above the
completed cohort, including outstanding-outcome headroom, not a practical allowance
for long-lived repeated retries. Exhaustion must refuse further new work while
preserving settlement reserves. This bounded store cannot serve indefinitely;
a larger realistic retention/retry envelope needs its own measurements and
separate review, not implicit Phase 11 retention or an unauthorized cleanup
procedure.
Maintain backup capacity separately and monitor failed-copy staging: preserved
failures and repeated crashes can consume any finite margin. Application callbacks
are trusted code, not memory-isolated sandboxes.

## Proven boundaries, limitations and release decision

Tests qualify the documented syscall/process crash model, generation revocation,
semantic replay, bounded admission and fixture compatibility. They do not certify
device caches, real hardware power cuts, malicious filesystem behavior or an
unreviewed deployment. Linux strict-sync requires an explicitly validated local
filesystem and truthful file/directory barriers; a Btrfs type check alone is not
hardware qualification. macOS `:write` is development only. Network/distributed
storage, unvalidated filesystems and relaxed production durability are unsupported.

Complete valid events participate in recovery even if prior caller success is
unknown. External effects are at-least-once; exactly-once side effects and fencing
of arbitrary external systems are not provided. Incomplete/corrupt/unsupported
history preserves evidence and refuses writable activation. A lost VM-local task
fence can require a new VM; it never grants overlapping execution by forgetting
an old callback. Torn-tail availability is intentionally fail-closed.

Cold whole-store backup/restore only is supported by the qualified procedure;
an older backup has an explicit RPO and may repeat effects. Do not concurrently
run copied STORE_IDs. Stored args are plaintext; directory ownership, permissions,
encryption and credential handling are deployment responsibilities.

Phase 11 snapshots/retention/compaction and Phase 12 orchestration/uniqueness stay
deferred. There is no live backup, automatic repair, distributed execution, new
storage format, or unbounded-history production promise.

R5 approves the **finite public-preview profile above**, the measured reference
target and the explicit target-validation condition. It does not approve an
arbitrary workload or deployment. Tay v0.5.0 remains an early public preview;
actual publication, tagging and pushing require separate authorization.
