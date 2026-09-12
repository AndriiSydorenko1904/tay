# Phase 3 implementation report

Phase 3 only is implemented against the approved
[recovery RFC](phase-3-recovery-rfc.md) and reconciled [TAY_PLAN.md](../TAY_PLAN.md).
G1–G6 are unchanged. Verification was performed on 2026-09-12 against the Phase 2
baseline commit `6743ea488e52200d79416470f1329ea013ee6c16`.

No Phase 4 work, production Event vocabulary/serialization, repair protocol or
Record/Segment/STORE format change is included.

## Implemented architecture and guarantees

1. Validate the explicit EventDecoder, pure reducer and operational options
   before acquiring storage. There is no default semantic provider.
2. The recovered Writer acquires existing ownership through opcode 18. The same
   Writer process, native Port/helper and flock remain continuously held through
   physical preflight, semantic replay, private reduction and activation.
3. Preflight validates the complete initialized physical history and topology
   before any semantic callback. A session-local view captures STORE bytes,
   inventories, file identities, summaries and physical checksums.
4. The additive halt-aware traversal validates each frame and sequence against
   that view before type/schema support, exact payload consumption and reduction.
   A callback failure stops immediately, closes the read descriptor and returns
   no successful accumulator. Existing physical accumulator semantics are intact.
5. Successful startup retains a private candidate in `awaiting_activation`.
   The creator is monitored; a finite lease expires without publishing state or
   creating storage. Status does not expose the candidate or an admission token.
6. Activation repeats full physical validation, compares the view and provider
   identity, and checks predicted successor/publication budgets before mutation.
   Opcode 19 then performs the deferred capability and ancestor/lock/root/segments
   barriers without releasing ownership. The existing Phase 2 protocol opens a
   valid active file or publishes an empty successor after a highest sealed file.
7. Only successful activation returns the candidate and a newly minted admission
   reference. Legacy unreferenced mutations, old session references and references
   from another owner/store cannot admit recovered-session mutations. Exhaustion
   produces terminal read-only state without a successor or admission reference.

All complete, physically valid, contiguous and understood events participate,
including records whose prior caller acknowledgement is unknown. This preserves
occupied sequences, not prior observed success or exactly-once semantics.

An incomplete Record, footer or canonical suffix is diagnosed and preserved.
No partial recovered state is published and writable activation is refused.
There is no truncation, padding, deletion, rename-aside, suffix repair, sequence
reuse, acknowledgement metadata, repair journal or watermark. Recognized stages
are retained. Inspection/replay never bootstrap root, lock, STORE or segments.

Pre-activation failures preserve file bytes, lengths, identities and namespace.
Reads can update access times and caches; this is not forensic zero-I/O.
After mutation-capability activation, an uncertain syscall/reply/deadline outcome
poisons the session and is explicitly `:uncertain_activation`, not a retryable
untouched resource refusal. No uncertain mutation is automatically repeated.

## Complete implementation file inventory

Modified in this implementation:

| File | Change |
| --- | --- |
| `lib/tay/storage/native.ex` | Existing-only acquisition, strict new-operation replies, per-Port capability, generation and deadline, same-session promotion; test-only pre-acquisition fault hook |
| `c_src/tay_storage_helper.c` | Opcodes 18/19, inspection permission state, bounded listing, deferred non-creating barriers, short-read and promotion fault sites |
| `lib/tay/storage/reader.ex` | Bounded preflight, frozen view, exact-coordinate halt-aware traversal and exception-safe cleanup; original physical APIs retained |
| `lib/tay/storage/segment/parser.ex` | Shared accumulator/visitor framing loop with explicit immediate error halt |
| `lib/tay/storage/segment.ex` | Minimal additive `reduce_while/5` delegation |
| `lib/tay/storage/writer.ex` | Recovered startup, retained candidate/lease, revalidation, promotion, terminal handling and distinct mutation admission; reuses Phase 2 publication |
| `test/tay/storage/native_protocol_test.exs` | Appended tests for existing acquisition, permission denial, listing limits, malformed packets and incompatible-helper refusal |
| `c_src/README.md` | New control messages, capability states, deferred barriers and test fault sites |
| `docs/architecture.md` | Recovery ownership, private state, semantic boundary, resource and activation contracts |
| `README.md` | Phase 3 scope, explicit recovery APIs, limitations and large-test command |

Created:

| File | Purpose |
| --- | --- |
| `lib/tay/storage/recovery.ex` | Coordinator, options, capability/consumption gates, result summaries, provider identity and revalidation budgets |
| `lib/tay/storage/recovery/error.ex` | Bounded classified diagnostics with preserved primary/cleanup errors and mutation status |
| `lib/tay/storage/recovery/event_decoder.ex` | Behaviour only; no production implementation |
| `test/support/recovery_helpers.ex` | Artificial test providers, pure reducers, independent fixture composition, evidence snapshots and bounded test-only eventual-lock-release assertions |
| `test/tay/storage/recovery_test.exs` | Public contracts, normal replay, coordinates, ownership references, provider changes and arithmetic exhaustion model |
| `test/tay/storage/recovery_semantics_test.exs` | Unknown semantics, consumption, callback failures, rejection, independent VM and external ACK observations |
| `test/tay/storage/recovery_adversarial_test.exs` | Torn/corrupt inputs, topology/identity changes, limits and no-mutation assertions |
| `test/tay/storage/recovery_lifecycle_test.exs` | Acquisition/replay/activation/append faults, helper and independent BEAM crashes, deadlines and Linux strict sync |
| `test/tay/storage/recovery_property_test.exs` | Generated multi-segment replay oracle and generated torn-tail refusal properties |
| `test/tay/storage/recovery_large_test.exs` | Opt-in real 1 GiB replay/activation and 300-segment budget/retry tests |
| `docs/phase-3-implementation-report.md` | This evidence and limitation report |

Total: 10 modified files and 11 created files. The already-modified TAY_PLAN.md
and already-present untracked Phase 3 RFC predate this implementation turn;
neither was edited here. They remain visible in worktree status and are not new
implementation changes. No files were deleted. Build/test outputs are ignored
artifacts, not source changes. Disposable fault-test stores are removed only by
the test harness after assertions, never by Recovery.

## Verification commands and results

All final verification commands in this section exited 0. Existing Phase 1/2
tests run in the same complete suite; none was removed, weakened or rewritten.
The existing native protocol test file has additions only (126 lines, zero
deletions). The other tracked test files have zero diff from the Phase 2 baseline.

| Exact command or named block below | Final result |
| --- | --- |
| `mix format --check-formatted` | Passed, no output |
| `mix compile --warnings-as-errors` | Passed; Elixir/native compilation clean |
| `mix test --warnings-as-errors` | 276 passed: 10 properties + 266 tests; 10 skipped; seed 949488; 25.2 s |
| Linux strict-sync full suite | 283 passed: 10 properties + 273 tests; 3 skipped; seed 203135; 21.5 s |
| `TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized mix test --warnings-as-errors` | 276 passed: 10 properties + 266 tests; 10 skipped; seed 610593; 27.3 s; no ASan/UBSan diagnostics |
| Linux strict-sync sanitizer suite | 283 passed: 10 properties + 273 tests; 3 skipped; seed 521562; 22.1 s; no ASan/UBSan diagnostics |
| `TAY_LARGE_SEGMENT_TEST=1 TAY_LARGE_RECOVERY_TEST=1 mix test test/tay/storage/segment_large_test.exs test/tay/storage/recovery_large_test.exs --warnings-as-errors` | 3 passed, no skips; seed 325704; 450.4 s |
| Development startup block | Empty root supervisor; no recovery/application wiring added |
| Production startup block | Missing configuration rejected; explicit path accepted without creating it; empty supervisor; no test provider or fault API |
| Fixture hash and unchanged-contract checks below | Passed; all 46 tracked fixture files byte-identical |
| `git diff --check` | Passed; no whitespace diagnostics |

`mix format` was run during implementation before the final check. The large
run covers the unchanged lazy Phase 2 exact-1-GiB parser test, a newly generated
real exact-1-GiB sealed segment through recovery and successor activation, and
300 small segments. The real segment contains 64 independently framed records;
the candidate is a constant-size count/byte-total pair. Traced native reads are
at most 16,777,244 bytes, and traversal covers more than three passes of the
records. This demonstrates bounded read requests and non-history-sized candidate
retention, not a platform-independent peak-RSS guarantee. No giant fixture is
committed. Its record encoder is independent; the test's incremental whole-file
CRC uses the existing CRC implementation, complemented by the unchanged Phase 2
lazy test and fixed fixtures with independent CRC oracles.

### Platforms and explicit skips

macOS 26.6.2 (25G83), local APFS development write path; Elixir 1.20.2 / OTP 29
(ERTS 17.0.2). The macOS full/sanitizer suites each skip seven Linux-only strict
sync tests (five existing, two new) and the three opt-in large tests. All three
large tests passed separately on macOS. macOS is not granted strict-sync support.

Linux uses `elixir:1.20.2` and the existing dedicated test data volume
`tay-phase2-20260912-validation`, not the container overlay or a temporary RAM
filesystem. Its actual filesystem was checked explicitly:

```sh
docker run --rm --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data elixir:1.20.2 stat -f -c '%T' /tay-data
```

Result: `btrfs`, exit 0. The tests select `durability: :sync` with
`validated_filesystem: true` on this test volume. Linux full/sanitizer runs skip
only the three opt-in large tests; large tests were not duplicated on Linux or
under sanitizers. Full native protocol, lifecycle and ownership coverage is
included on both platforms. Sanitizer builds use the existing compiler flags
`-fsanitize=address,undefined -fno-omit-frame-pointer -g` for both native binaries.

Linux strict-sync full suite:

```sh
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 elixir:1.20.2 mix test --warnings-as-errors
```

Linux strict-sync sanitizer suite:

```sh
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/sanitized-phase3 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_NATIVE_SANITIZE=1 elixir:1.20.2 mix test --warnings-as-errors
```

Development startup:

```sh
mix run -e '[] = Supervisor.which_children(Tay.Supervisor); IO.puts("development startup: empty supervisor")'
```

Production startup:

```sh
MIX_ENV=prod mix run --no-start -e 'Application.delete_env(:tay, :data_dir); {:error, {:tay, {{:invalid_config, :data_dir, message}, {Tay.Application, :start, _}}}} = Application.ensure_all_started(:tay); IO.puts(message); Application.put_env(:tay, :data_dir, "/operator-configured/tay-phase3-startup-check"); {:ok, _} = Application.ensure_all_started(:tay); [] = Supervisor.which_children(Tay.Supervisor); false = File.exists?("/operator-configured/tay-phase3-startup-check"); Code.ensure_loaded!(Tay.Storage.Native); false = function_exported?(Tay.Storage.Native, :fault, 6); false = Code.ensure_loaded?(Tay.Test.RecoveryDecoder); IO.puts("production startup: empty root, no storage I/O, no test provider/fault API")'
```

The expected production missing-config notice is a tested refusal, not a failed
verification. Environment-prefixed Mix/startup commands initially hit sandbox
TCP build-lock `:eperm`; the same commands were rerun with approval and passed.
Docker inspection and a process-status diagnostic also required sandbox approval.

## Fault, adversarial and resource coverage

- Every nonempty partial prefix of the representative Record, all partial footer
  lengths 1–63 and canonical header lengths 0–43 refuse activation with unchanged
  evidence. Every byte of a representative frame is corrupted in turn. Length
  corruption with recomputed header CRC cannot silently swallow later valid data.
- Unknown type/schema and invalid payload in A/B/C halt before semantic C; later
  physical corruption takes precedence over unknown earlier semantics. Zero,
  partial, excessive and noninteger consumption are rejected. No ETF or bytes
  fallback exists. Test meanings live exclusively in `test/support/`.
- Callback bad shapes, exceptions, throws, exits, capability changes and late
  reducer rejection publish no partial result. A primary semantic failure plus
  failed close preserves both diagnoses and closes the uncertain connection.
- Topology/anchor/duplicate/trailing-byte errors, unsupported STORE, retained and
  oversized stages, lock links, changed inventories and same-inode rewrites are
  refused. Replay checks pinned sequence before invoking a semantic visitor.
- Existing acquisition crash-before/crash-after, dropped/mismatched reply and
  unsupported opcode refusal preserve namespace. Every inspection mutation
  opcode is denied, including sync and open-for-write. Acquisition never falls
  back to creating storage.
- Preflight list/open/read/close failures, short reads, helper crashes, dropped
  and mismatched replies; Q5 read/close/check failures; activation expiry and
  startup/revalidation/post-promotion deadlines preserve their distinct results.
- All deferred promotion barrier classes (ancestor, lock, root, segments) are
  exercised with I/O error, crash-before, crash-after and dropped reply. Failures
  prevent readiness; uncertain promotion is never retried.
- Highest-sealed activation crashes at R3–R7 and create/sync/close substeps retain
  the exact permitted old history/stages and require full replay on restart.
  Existing Phase 2 tests continue to cover publication collisions, both writable
  closes, file/directory barriers and active-open failure ordering.
- Independent BEAM contenders remain excluded before and after activation by
  the same helper. Owner death during reduction returns no candidate. A complete
  append with lost reply is replayed and keeps its occupied sequence; a native
  partial footer repeatedly refuses restart without altering its bytes.
- Linux tests include strict recovered-session acknowledgement followed by
  abrupt independent BEAM exit and complete failed-sync append recovery. An
  external test harness varies ACK observations for identical histories; no
  production ACK ledger, selector or metadata is introduced.
- Separate tests cover payload decode budget, directory entry budget, total
  canonical bytes, replay record count, decoder depth/output-node/binary-byte
  limits, reply timeout, whole-attempt deadline and activation lease/deadline.
  Invalid, duplicate and unknown options are rejected before acquisition.
  Exact 16 MiB physical payloads remain valid when a smaller operational decode
  budget refuses them. Retry with sufficient budgets succeeds without repair.
- Budgets that admit existing history but cannot afford an empty successor or
  temporary publication inventory fail before promotion with unchanged storage.
  Native listing returns no partial success on its cap. The 300-segment test
  independently verifies refusal and successful larger-budget retry.
- Two new StreamData properties (30 generated cases each per run) compare
  multi-segment replay with an independent reducer oracle and verify generated
  torn tails never publish or mutate. Existing eight properties are unchanged.

## Compatibility evidence

Before and after implementation, this exact command produced identical output
for all 46 tracked files (18 Record binary fixtures, 22 Segment/STORE binary
artifacts, and six manifests/materializers/documentation files):

```sh
git ls-files -z test/fixtures/storage | xargs -0 shasum -a 256
```

The SHA-256 of that complete ordered hash listing is
`ecab6df7e7bd5215c1f85daee397ab484bb7a23cce90941fb9c77d28267b1004`:

```sh
git ls-files -z test/fixtures/storage | xargs -0 shasum -a 256 | shasum -a 256
```

These unchanged-contract checks also returned exit 0 and no diff:

```sh
git diff --exit-code -- lib/tay/storage/record.ex lib/tay/storage/crc32c.ex test/fixtures/storage docs/phase-1-storage-format-rfc.md docs/phase-2-segment-format-rotation-rfc.md lib/tay/job.ex lib/tay/application.ex lib/tay/worker.ex config mix.exs mix.lock
git diff --exit-code -- test ':!test/tay/storage/native_protocol_test.exs'
```

Record v1 remains its approved 24-byte header, 28-byte total overhead, CRC32C
coverage, sequence/numeric domains and 16 MiB payload hard limit. STORE v1 stays
28 bytes; segment v1 stays a 44-byte header, 64-byte footer, 20-digit names and
1 GiB hard bound with unchanged CRCs, anchors and topology. Segment parsing's
only format-adjacent change is shared visitor control flow, not validation or
wire decoding. No binary fixtures were regenerated. Opcodes 18/19 are the
approved internal control additions, not persisted format revisions.

## Issues corrected during implementation

No unresolved correctness or data-loss issue requiring an RFC/format decision
was found. Development and verification did expose the following, all corrected
before the final passing runs:

- An initially overstrict post-publication inventory comparison rejected valid
  APFS successor activation: APFS changed the `segments` directory's link count
  from 3 to 4 and size from 96 to 128 while retaining its inode. Only those two
  directory metadata fields are normalized after the authorized publication;
  inode/device/mode and the exact complete child inventory are still checked.
  Pre-mutation Q5 view comparison remains exact. The initial result was
  fail-closed refusal, not lost data or an accepted changed history.
- New tests initially allowed only 200 ms for ordinary helper startup before
  fault injection; full-suite scheduling could consume that budget. New fault
  tests now use ordinary setup budgets (2 s for intentionally dropped replies,
  otherwise 10 s), preserving the same evidence and failure assertions. The
  explicit deadline tests still expire deliberately. Production defaults did
  not change.
- Sanitizers exposed immediate-reacquisition assumptions in new tests following
  forced Port closure. OS helper exit/flock release is asynchronous. The tests
  now assert eventual release with a bounded 5 s test-only retry of *busy only*;
  any other outcome is returned immediately. Production acquisition/mutations
  do not gain retries and never bypass a live lock.
- Warnings-as-errors caught unused aliases in new tests; they were removed.
  The intentional hot-provider replacement warning is explicitly captured and
  asserted by that test, not globally suppressed.

For transparency, intermediate `mix test --warnings-as-errors` runs included
exit 1 for unused aliases and an exit-2 run with 271/272 passing before the test
startup budget correction. The six-file recovery/native targeted command below
initially had 61/78 passing before the APFS comparison correction, then 78/78
and later 85/85 passing as tests were added. Initial sanitizer full runs had
268/272 and 275/276 passing before the new eventual-release assertions. The
final commands/table supersede those development runs, not their evidence.

```sh
mix test test/tay/storage/recovery_test.exs test/tay/storage/recovery_semantics_test.exs test/tay/storage/recovery_adversarial_test.exs test/tay/storage/recovery_lifecycle_test.exs test/tay/storage/recovery_property_test.exs test/tay/storage/native_protocol_test.exs --warnings-as-errors
```

## Deviations, coverage limits and remaining dependencies

No intentional RFC or G1–G6 deviation. All changes remain within RFC §18's file
boundaries. No new dependency or application startup wiring was introduced.

The operational defaults remain exactly the approved ones: 16 MiB decode,
100,000 directory entries, unlimited total canonical bytes/record count,
900,000 ms replay/activation deadlines, 30,000 ms activation window, 10,000 ms
per reply, and Event limits depth 64 / output nodes 100,000 / binary bytes
16,777,216. They are not persisted and never redefine physical validity.

The exhaustion boundary is tested with an arithmetic model and rejection of an
invalid max-FIRST genesis, not a fabricated tiny "valid" uint64-scale history.
A full physical genesis-to-uint64-max terminal activation is not practically
generated; its terminal branch also relies on the unchanged Phase 2 arithmetic
and descriptor protocol. This is a coverage limitation, not a new replay anchor
or permission to bypass complete-history validation.

Providers/reducers are trusted, pure, bounded code. Module fingerprints detect
provider replacement; dependency hot reload and mutable external configuration
must still be prohibited by the embedding owner. Cooperative callback deadlines
are not a sandbox against arbitrary hung/native/side-effecting user code.
Consumer accumulator memory remains the consumer's responsibility.

Production Event meanings, serialization, schema evolution and semantic golden
fixtures require their separate future RFC. No real job-state recovery can be
claimed yet. Automatic torn-tail repair remains separately reviewed future work.
No ETS projection, job transition, insertion API, scheduling, dispatch, snapshot,
manifest or other Phase 4 scope is present.

Linux test-volume validation is not hardware/controller certification. Tests
exercise software ordering, actual independent process crashes and injected
syscall failures, not real power cuts or device-cache dishonesty. No XFS/ext
deployment certification, macOS full-sync protocol or release installation was
performed. CRCs do not defend against deliberate collision construction, and
loss of a clean complete suffix can remain undetectable if storage violates its
durability assumptions. These existing guarantees/non-guarantees are unchanged.

**Phase 3 implementation and verification complete. Stop here; Phase 4 is not
started.**
