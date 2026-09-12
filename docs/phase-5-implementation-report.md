# Phase 5 implementation report — Complete Execution Lifecycle

**Phase 5 complete — mandatory acceptance checkpoint passed.**

Date: 2026-09-13. Baseline HEAD:
`e1e0fe3c8b1e29ff0dccf6a053fcff1504a738ed` (accepted Phase 4).
No commit, tag or release has been created for this work. This report records
implementation and the completed acceptance matrix before crossing into Phase 6.
Phase 6 has not been implemented at
this checkpoint. R5's measured production envelope remains a Phase 6 release gate.

## Authority and scope

The approved accelerated roadmap, Event v1 appendix, R1–R4 decisions, frozen
Phase 1–3 contracts and approved Phase 5 verification policy govern this work.
Historical “submitted for approval” wording in the RFCs does not supersede the
user's explicit approvals. G1–G6 and Event schema 1 have not been reinterpreted.

Implemented scope: supervised waiting callback tasks and trusted relays; durable
start authorization; bounded outcome normalization; monotonic timeouts; stored
retry due times; scheduled availability; interrupted-execution reconciliation;
executing/queued cancellation; revision-checked manual retry; queue concurrency,
bounded control demand and runtime status. All producers use the existing six
Event schemas and the existing pure transition model.

No Phase 6 pause/resume, drain, stop/restart facade, storage Mix tasks, packaging,
release qualification or production-capacity claims are included here. No Phase
11/12 snapshots, retention, compaction, manifests, orchestration or uniqueness;
no automatic repair, distributed execution or exactly-once external effects.

## Created and modified files

Inventory captured with `git status --short --untracked-files=all` against the
baseline above. Existing tracked files modified (10):

```text
lib/tay.ex
lib/tay/engine.ex
lib/tay/engine/admission.ex
lib/tay/engine/config.ex
lib/tay/engine/lifecycle.ex
lib/tay/engine/supervisor.ex
lib/tay/error.ex
lib/tay/state/projection.ex
lib/tay/state/scheduler_index.ex
test/support/engine_helpers.ex
```

Created implementation files (10):

```text
lib/tay/execution/clock.ex
lib/tay/execution/executor.ex
lib/tay/execution/local_fence.ex
lib/tay/execution/outcome.ex
lib/tay/execution/queue.ex
lib/tay/execution/registry.ex
lib/tay/execution/relay.ex
lib/tay/execution/retry.ex
lib/tay/execution/scheduler.ex
lib/tay/execution/supervisor.ex
```

Created test/support files (15):

```text
test/support/execution_helpers.ex
test/tay/engine/public_mutation_test.exs
test/tay/execution/clock_test.exs
test/tay/execution/control_test.exs
test/tay/execution/fault_test.exs
test/tay/execution/independent_vm_test.exs
test/tay/execution/lifecycle_test.exs
test/tay/execution/local_fence_test.exs
test/tay/execution/model_test.exs
test/tay/execution/outcome_test.exs
test/tay/execution/protocol_test.exs
test/tay/execution/readiness_test.exs
test/tay/execution/registry_test.exs
test/tay/execution/resource_test.exs
test/tay/execution/retry_test.exs
```

Created documentation: `docs/phase-5-implementation-report.md` (this report).
Final Phase 5 inventory: 10 modified and 26 created files.

The only existing test-support adaptation is an explicit `test_execution: false`
default in `Tay.Test.EngineHelpers`. This preserves the accepted Phase 4 tests'
inert-execution setup and every existing assertion. New Phase 5 helpers explicitly
enable execution. Production rejects the test-only switch. No existing test case,
assertion, expected result or fixture was weakened, removed or rewritten.

## Architecture and invariants

- Engine remains the only semantic writer, private-index owner and queue-credit
  authority. The same recovered Writer/native helper/Port/flock remains in use
  through activation and live operations. No storage path or native opcode changed.
- Queue and Scheduler own bounded timers/demand, not job state. Engine reads
  bounded index selections, emits normal Events, and installs their projected
  effects. Queue restart does not reset Engine's running credits. Demand across
  queues remains bounded; unavailable mappings do not monopolize ready heads.
- Reserve a queue credit and create a supervised relay and waiting task before
  start persistence. Commit and project `job_started` before sending that exact
  task its generation/execution authorization. Callback code runs outside Engine,
  Writer, replay and queue control. Waiting for durable start consumes no timeout.
- The relay accepts one normalized outcome, matched to the exact physical token.
  `job_finished` atomically stores outcome and retry/discard disposition. Runtime
  credit is released only after durable settlement and confirmed task death.
  A per-job local hold also prevents another free queue slot from admitting a
  retry while that job's previous callback remains alive.
- Actual worker failure or stored timeout consumes the logical attempt. After
  fresh activation, unmatched executing history is settled as interrupted using
  the same logical ordinal, including at `max_attempts`; the next start receives
  a new physical execution token. Reconciliation does not change replay or repair
  storage, and dispatch/readiness remain closed until reconciliation succeeds.
- Cancellation is persisted before best-effort termination. Late results cannot
  replace a cancellation or settled timeout. Cancelled/completed work cannot be
  revived by manual retry. Expediting retryable work preserves its cycle/ordinal;
  retrying discarded work starts a new cycle using the original stored policy.
- `Tay.cancel/2` and `Tay.retry/2` accept `:name`, `:timeout` and an opaque
  `:expected_revision`. If omitted, lookup captures the revision once. No automatic
  refresh or RPC retry follows conflict, timeout or an unknown outcome. Submitted
  mutation losses carry the captured revision, job ID and operation in `Tay.Error`.
- Eligibility uses captured wall time, rechecked after persistence and before
  callback entry; timers are only bounded wakeups. Callback deadlines use monotonic
  time from release. Replay consults neither clock nor randomness. Wall-clock
  reversals do not imply a rewrite of historical Event timestamps.
- Retry policy is the immutable v1 arithmetic: 1000 ms exponential base, 60,000 ms
  cap, inclusive bounded jitter and saturation at the approved Time maximum.
  Unbiased rejection sampling chooses a due time once; only that chosen time is
  persisted. No raw result, exception callback, reason, stack or module name is
  serialized into the code-only diagnostic.
- Worker lookup uses inert stable keys and explicitly configured module atoms.
  Trusted configured modules may be loaded during runtime setup after pure replay;
  persisted text is never converted to an atom/module or used as a code-loader name.
- Guardian closes admission on infrastructure loss and revokes the whole execution
  generation. Readiness checks current runtime/fence health, not merely whether a
  queued DOWN message has already been processed. Old indexes and capabilities
  cannot authorize a new generation.

### Local execution fence

`Tay.Execution.LocalFence` is a lazily started VM-local owner ledger keyed by
STORE_ID. It prevents a differently named Engine from activating while callbacks
registered to the previous local generation remain alive. Registration occurs
while a task is still waiting, before release. It records only process identities
and volatile tokens, not job payloads or persisted acknowledgement metadata.

A small `persistent_term` marker precedes each lease grant. Lease retirement
requires proven callback death. If the ledger process dies with an outstanding
marker, a replacement refuses that STORE_ID with `:local_fence_lost`; **a fresh
VM is required**. There is no API to erase/adopt an orphan marker. This fail-closed
implementation refinement preserves R4's already-approved local-death guarantee;
it is not a storage format, recovery ticket, distributed fence or new Event.

## Resource limits and admission

All Phase 3 recovery budgets and Phase 4 insertion/candidate/client-admission
defaults remain unchanged. Runtime controls do not turn operational budgets into
physical or semantic validity rules.

- `execution_batch`: default 32, accepted 1..1024; bounded due/reconciliation work.
- `execution_wake_ms`: default 1000, accepted 1..1000. A capacity-refused due head
  waits for the configured interval, not a forced millisecond polling loop.
- Callback/relay/outcome slots are bounded by configured queue concurrency.
  Scheduler and each queue have bounded outstanding control demand; Engine
  coalesces wake signals. Execution-status publication has one pending reference
  plus a dirty bit, not one queued snapshot per control iteration.
- Existing client permits bound payload-bearing requests before submission.
  Outcomes and scheduled availability progress independently of occupied client
  permits. Submitted permit ownership survives caller timeout/death.
- Before starting work, Engine verifies all finish classes fit operational Event
  budgets and reserves sequence/segment headroom for active settlements. New
  insertions/starts cannot spend that reserve. This is conservative arithmetic,
  not a promise against actual ENOSPC, device faults or unlimited repeated crashes.
- Jitter uses at most 128 unbiased 16-bit draws. Entropy failure or repeated
  rejection returns a bounded infrastructure error; it never substitutes biased
  randomness or invents a retry due time. Zero-jitter and terminal outcomes do
  not require an entropy draw.
- Status reports finite charged-state counters, active/queue credits, outcome and
  control slots, and reconciliation progress. It remains a bounded, potentially
  stale snapshot, not a linearizable job lookup, recovery certificate or exact-RSS
  measurement. Task-supervisor liveness probing uses constant-size counters rather
  than copying the entire active-child list per outcome.

## Focused verification already completed

These are development-slice results, not substitutes for the final acceptance
matrix. Repeated selections overlap; their counts must not be added together.
No expensive scale/platform matrix was repeatedly run during implementation.

| Exact command | Observed result |
| --- | --- |
| `mix compile --warnings-as-errors` | Passed after completed slices, including the final protocol refinement |
| `git diff --check` | Passed at implementation checkpoints |
| `mix test test/tay/execution/clock_test.exs test/tay/execution/retry_test.exs test/tay/execution/outcome_test.exs test/tay/execution/registry_test.exs test/tay/engine/public_mutation_test.exs test/tay/engine/admission_test.exs test/tay/state/transition_test.exs --warnings-as-errors` | 31 passed: 5 properties, 26 tests; seed 750291; 2.0 s |
| `mix test test/tay/engine/core_test.exs test/tay/engine/fault_test.exs test/tay/engine/lifecycle_test.exs test/tay/engine/config_test.exs test/tay/state/projection_test.exs --warnings-as-errors` | 37 passed, 1 skipped; seed 206943; 4.0 s |
| `mix test test/tay/execution/model_test.exs test/tay/execution/lifecycle_test.exs --warnings-as-errors` | 20 passed: 1 property, 19 tests; seed 514024; 2.0 s |
| `mix test test/tay/execution/model_test.exs test/tay/execution/lifecycle_test.exs test/tay/engine/lifecycle_test.exs --warnings-as-errors` | 25 passed: 1 property, 24 tests; seed 557170; 2.0 s |
| `mix test test/tay/execution/model_test.exs test/tay/execution/lifecycle_test.exs test/tay/execution/protocol_test.exs --warnings-as-errors` | 35 passed: 1 property, 34 tests; seed 339118; 2.9 s |
| `mix test test/tay/execution/fault_test.exs test/tay/execution/protocol_test.exs --warnings-as-errors` | 58 passed, 1 Linux-sync-only skip; seed 256667; 5.1 s |
| `mix test test/tay/execution/protocol_test.exs --warnings-as-errors` | 15 passed after constant-size task-supervisor liveness refinement; seed 736020; 1.5 s |
| `mix test test/tay/execution/control_test.exs --warnings-as-errors` | 7 passed; seed 699651; 1.1 s |
| `mix test test/tay/execution/control_test.exs --warnings-as-errors --seed 42` | 7 passed; seed 42; 1.2 s |
| `mix test test/tay/execution/resource_test.exs test/tay/execution/control_test.exs --warnings-as-errors` | 10 passed; seed 705794; 1.4 s |
| `mix test test/tay/execution/resource_test.exs test/tay/execution/model_test.exs test/tay/execution/readiness_test.exs --warnings-as-errors` | 9 passed: 1 property, 8 tests; seed 496919; 1.7 s |

Scoped formatting commands, including `mix format test/tay/execution/control_test.exs`
and `mix format lib/tay/execution/relay.ex`, passed. Whole-tree formatter and final
warnings-as-errors compilation remain explicit acceptance checks below.

## Fault, race and model coverage

| Area | Implemented and verified checks |
| --- | --- |
| Start authorization | Barriers at waiting-task creation, start pre/post-append, projection and release; no callback before authorization; durable start without callback entry is interrupted on recovery |
| Effects versus acknowledgement | Independent callback-entry/effect observations; crash before/after finish commitment; duplicates after uncertain external effects are allowed, invented completion/lost job is not |
| Independent BEAM crash/restart | First VM halts after a real callback effect at ordinal 1/start sequence 2; fresh VM replays interruption, executes ordinal 1/start sequence 5 and completes at revision 6; external oracle records both effects |
| Finish/cancel/retry persistence | Full, torn and lost-response boundaries; exact live/replay outcomes; complete unacknowledged Events remain authoritative; incomplete suffixes preserve evidence and refuse activation |
| Callback normalization | Success/error/raise/throw/exit/invalid return, huge return and external exit terms, code-only diagnostics, no raw application terms in default logs |
| Timeout and cancellation fencing | Chosen timeout beats late success; executing cancellation commits before termination; deliberately delayed death retains the job hold and queue credit even with another free slot |
| Infrastructure lifecycle | Engine, Writer/helper, relay, guardian, runtime and task-supervisor losses; repeated interruption at maximum attempts; no synthetic worker failure for infrastructure loss |
| Readiness/reconciliation | Runtime/fence loss queued behind ready; no publication from stale monitor state; crash after one reconciliation batch resumes complete committed progress without losing attempts |
| Local owner exclusion | Same STORE_ID under different instance names; exact task registration/death; creator loss; orphan-ledger fail-closed behavior; normal retirement |
| Scheduling and fairness | Fake-clock reversals/forward jumps/equal due times; queue/scheduler restarts; unavailable/removed mappings; bounded two-queue progress; no 1 ms capacity-refusal loop |
| Admission and mailbox bounds | All client slots occupied while schedules/outcomes progress; 128 client operations with suspended coordinators and coalesced wakes; suspended guardian receives at most one execution snapshot |
| Retry and model oracle | Exhaustive 64,008-sample accepted-prefix jitter histogram; entropy failures; saturation; generated failure/timeout/interruption/manual-cycle histories compared with independent ordinal expectations and pure replay |
| Coordinate/resource limits | Starts reserve settlement coordinates; insertion cannot consume active reserve; known pre-I/O refusal preserves bytes; configuration limits remain operational |

These are process/message/syscall fault tests, not real hardware power-cut or
device-cache certification. Arithmetic exhaustion tests do not materialize 2^64
records or segments. Final platform-specific skips must be recorded explicitly.

### Development failures and corrections

Normal intermediate failures were investigated rather than hidden by weaker
assertions or format changes:

- Compilation during parallel Engine edits encountered not-yet-defined private
  functions; completed slices compiled successfully. A test-local Inspect protocol
  implementation warned after consolidation; the new test instead uses a hostile
  exception callback without modifying compiler or protocol settings.
- Runtime child restart configuration and ordinary shutdown cleanup were corrected
  so generation revocation cannot restart a component beneath surviving state.
- Asynchronous task-death bookkeeping could race normal relay DOWN and falsely
  revoke a healthy generation. Relay death confirmation now waits for exact
  guardian/fence acknowledgement before normal exit.
- Task-supervisor loss could otherwise look like callback failure when child DOWN
  arrived first. Infrastructure health is checked before selecting the bounded
  worker outcome; its final probe returns constant-size counters.
- Unconditional wake and execution-status messages could accumulate at suspended
  recipients. Coalescing now bounds both paths, with dedicated suspension tests.
- A mapped but unavailable worker could block an entire queue head. Runtime
  dispatch indexing filters unavailable mappings without touching replay or history.
- Queued readiness could precede an infrastructure DOWN notification. Readiness
  now verifies current fence/runtime health, with deterministic adverse ordering.
- A durable start's waiting task could die while wall time remained below its
  eligibility and remain unsettled. Such pre-release death revokes the generation
  independently of wall time, allowing normal interrupted reconciliation.
- Initial new-test cleanup raced an already shutting-down root; explicit test
  shutdown corrected that harness ordering. New status assertions use the approved
  bounded-snapshot semantics, not unsupported immediate publication assumptions.

No approved semantic or byte-level contract was altered to address these defects.
No frozen-contract contradiction or unresolved correctness failure was identified
in independent review or final acceptance. A sandbox attempt at the added host
sanitizer test failed before execution because Mix could not acquire its TCP
build lock (`:eperm`); the same command passed after permission was granted.

## Fixture and frozen-contract evidence

Read-only checks performed during report preparation:

```sh
git diff --exit-code -- lib/tay/storage c_src lib/tay/event.ex lib/tay/event lib/tay/state/transition.ex test/fixtures test/tay/storage test/tay/event test/tay/state
git ls-files -z test/fixtures/storage | xargs -0 shasum -a 256 | shasum -a 256
shasum -a 256 test/fixtures/events/v1/SHA256SUMS
```

All commands exited 0. Storage fixture inventory SHA-256 remains:

`ecab6df7e7bd5215c1f85daee397ab484bb7a23cce90941fb9c77d28267b1004`

Event literal manifest-file SHA-256 remains:

`092abb6de9965b1077edd88e4316d89474595fb2500a0783b920ba440b3cbae0`

The independent literal/hash comparison below exited 0 and printed
`50/50 approved literal vectors and decoded-byte SHA-256 hashes match`:

```sh
ruby -rdigest -e 's = File.read("docs/event-v1-contract-appendix.md"); vectors = {}; s.scan(/^#### ([EN][0-9]+)\n\n```hex\n(.*?)```/m) { |id, hex| vectors[id] = hex.gsub(/\s/, "") }; s.scan(/^\| ([VX][0-9]+)[^\n]*?\| `([0-9a-f]+)` \| `([0-9a-f]{64})` \|/) { |id, hex, hash| vectors[id] = hex }; abort "wrong count" unless vectors.size == 50; manifest = File.readlines("test/fixtures/events/v1/SHA256SUMS").to_h { |line| hash, file = line.split; [File.basename(file, ".hex"), hash] }; vectors.each { |id, hex| actual = File.read("test/fixtures/events/v1/#{id}.hex").gsub(/\s/, ""); abort id unless actual == hex && Digest::SHA256.hexdigest([actual].pack("H*")) == manifest[id] }; puts "50/50 approved literal vectors and decoded-byte SHA-256 hashes match"'
```

All 46 legacy storage fixture files and all 50 approved Event vectors remain
byte-identical. Record v1, STORE v1 and Segment v1 contracts are unchanged;
Reader/Writer/recovery/native implementation paths are unchanged. Event schemas,
literal hashes, retry constants and pure `Tay.State.Transition` are unchanged.

## Final acceptance matrix — PASSED

macOS toolchain: Darwin 25.6.0 arm64, Elixir 1.20.2, Erlang/OTP 29 / ERTS 17.0.2.
Linux uses `elixir:1.20.2` and the explicitly revalidated local Docker Btrfs volume.
The final test inventory contains 484 cases: 123 more than the accepted Phase 4
inventory. Existing test assertions and all physical/Event fixtures remain intact.

| Required gate | Final command/result |
| --- | --- |
| Whole-tree formatter | Passed — `mix format --check-formatted` |
| Warnings-as-errors compilation | Passed — `mix compile --warnings-as-errors` |
| Complete ordinary suite / macOS development verification | Passed — `mix test --warnings-as-errors`; **471 passed: 19 properties, 452 tests; 13 skipped**; seed 951676; 46.4 s |
| Event v1 conformance and unchanged Phase 1–4 regression fixtures | Passed in complete ordinary suites; independent byte/hash checks above also passed |
| Complete Phase 5 execution/race/fault matrix | Passed in complete macOS/Linux ordinary suites and sanitizer coverage, including the Linux-only finish-sync case and independent-BEAM extension |
| Linux strict-sync on explicitly validated local Btrfs | Passed — exact commands below; **480 passed: 19 properties, 461 tests; 4 skipped**; seed 165502; 42.9 s |
| macOS ASan/UBSan full suite | Passed — **470 passed: 19 properties, 451 tests; 13 skipped**; seed 993279; 58.5 s |
| Linux/Btrfs ASan/UBSan full suite | Passed — **479 passed: 19 properties, 460 tests; 4 skipped**; seed 439695; 43.0 s |
| 10,000-job reconstruction, once at final verification | Passed on Linux strict-sync — **1 passed**; seed 952037; 6.7 s; exact opt-in command below |
| Final independent-BEAM execution/crash extension | Passed in both final ordinary suites; additional ASan/UBSan runs: macOS **1 passed**, seed 410565, 2.2 s; Linux **1 passed**, seed 74243, 3.0 s |
| Final unchanged-contract check and file inventory | Passed — byte-only diff and fixture hashes unchanged; final file inventory above |

Final review added the independent-BEAM test after the first matrix run. The first
ordinary runs passed 470/macOS (seed 415343, 44.5 s) and 479/Linux (seed 359514,
40.8 s). Both ordinary suites were rerun with the final inventory, yielding the
471/480 totals above. Production source did not change after the full sanitizer
runs: their 470/479 passing cases plus the separately sanitized new VM case cover
the final inventory. These are explicitly separate runs, not invented single-run
totals. The 10,000-job gate ran once; the new execution-only test did not require
repeating storage-scale qualification.

Explicit Event-only verification also passed:
`mix test test/tay/event/codec_test.exs test/tay/event/atom_independence_test.exs --warnings-as-errors`
— **11 passed: 2 properties, 9 tests**, seed 993530; 0.1 s.

The Linux data volume was rechecked and returned `btrfs`; strict-sync storage
uses that named local volume, not the repository bind mount. Exact completed
platform commands:

```sh
docker run --rm --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data elixir:1.20.2 stat -f -c '%T' /tay-data
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 elixir:1.20.2 mix test --warnings-as-errors
TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized mix test --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/sanitized-phase5 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_NATIVE_SANITIZE=1 elixir:1.20.2 mix test --warnings-as-errors
TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized mix test test/tay/execution/independent_vm_test.exs --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/sanitized-phase5 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_NATIVE_SANITIZE=1 elixir:1.20.2 mix test test/tay/execution/independent_vm_test.exs --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_LARGE_RECOVERY_TEST=1 elixir:1.20.2 mix test test/tay/engine/large_recovery_test.exs --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix run -e 'IO.inspect(Supervisor.which_children(Tay.Supervisor)); IO.inspect(Tay.status())'
elixir -pa _build/prod/lib/tay/ebin -e 'for mod <- [Tay.Engine.Config, Tay.Storage.Writer], do: Code.ensure_loaded!(mod); {:error, _} = Tay.Engine.Config.new(data_dir: "tmp/prod-check-unused", durability: :write); for option <- [[test_execution: false], [test_clock: Tay.Execution.Clock], [test_terminate: fn _ -> :ok end], [test_hook: fn _ -> :ok end]], do: ({:error, _} = Tay.Engine.Config.new([data_dir: "tmp/prod-check-unused"] ++ option)); false = function_exported?(Tay.Storage.Writer, :inject_fault, 6); {:error, :nofile} = Code.ensure_loaded(Tay.Test.ExecutionWorker); IO.puts("production refuses development/test switches; no fault API or test worker")'
```

All exited 0. Application startup printed `[]` and an unavailable status; it did
not start execution or open storage implicitly. Production compilation passed.
A production Elixir probe confirmed development/test options are refused,
`Writer.inject_fault/6` is absent, and the test ExecutionWorker is unavailable;
its exact command appears above. Neither sanitizer suite reported an ASan/UBSan
finding. These checks do not certify a storage device's power-loss behavior.

The 13 macOS skips comprise nine platform-specific strict-sync checks and the four
opt-in large cases; Linux skips those four opt-in cases only. Strict-sync-enabled
suite counts also include explicit development/unsupported-mode tests and are
not a claim that every individual test performs a sync append.

The 1 GiB recovery and other expensive storage-scale tests are intentionally
deferred to Phase 6 under the approved speed policy: no Record, Segment, Reader,
Writer, recovery or native storage path changed in Phase 5. Any such change or
suspected relevant regression immediately restores the affected expensive tests
to this gate. This deferral does not reduce new execution/race/fault coverage.

## Limitations, deviations and boundary decision

There is no Event/R1–R4 semantic deviation. LocalFence, bounded
entropy attempts, explicit counter-based health checks and coalesced control/status
messages are runtime implementation refinements, not new persisted decisions.

Existing durability limits remain: explicit macOS `:write` is development mode,
not acknowledged durability; production `:sync` requires the existing supported,
explicitly validated Linux filesystem assumptions. No new platform/filesystem is
qualified by this report. A torn/corrupt canonical history preserves all bytes and
refuses writable activation; complete understood unacknowledged Events replay.

Arbitrary worker-created unlinked processes, NIF hangs and external effects are
not a Tay sandbox. Cancellation cannot undo effects, interruption can repeat
effects, and a local-fence orphan requires VM restart. Retained history grows
without eviction; production capacity, restart envelope, restore procedure,
packaging and operations are Phase 6 work, not claimed here.

**Boundary decision: GREEN.** All Phase 5 functionality and required acceptance
coverage are complete. No unresolved correctness failures, frozen-contract
contradictions or unexplained regressions remain. No Phase 6 semantic shortcut
was used. The user's continuous authorization permits proceeding to Phase 6
after this checkpoint; it does not authorize a commit, tag or release.
