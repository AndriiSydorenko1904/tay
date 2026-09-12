# Phase 4 implementation report — Durable Job Core

Date: 2026-09-12. Baseline: `741d6cb724eab6daa8dc88f9c15a5eb0ca366bcb`,
HEAD/tag `v0.3.0`. Implementation is uncommitted; no commit, tag or release was
created. Phase 4 implementation and verification are complete. Phase 5/6 were
not implemented.

## Authority and scope

The user's approval of R1–R4 and explicit Phase 4 authorization govern this
implementation, including approval of the Event appendix despite its historical
“submitted for approval” heading. Both roadmap/appendix files were already
untracked at task entry and were preserved without edits. R5 remains a Phase 6
release gate. No G1–G6 or frozen physical contract was reopened.

Implemented: exact Event/value codec and all six schemas; one complete pure
transition model; production EventDecoder and bounded private recovery candidate;
private Job/Queue/Scheduler ETS projections; explicit Engine supervisor/lifecycle;
pre-payload bounded client admission; initialize-only administration; stable Job
IDs/definitions; builders, insert/get/status; exact same-ID reconciliation;
Writer poison/closure notification and whole-generation revocation.

Only `job_inserted` is produced live. All six types are decoded and transitioned
in the pure model, including recovered executing state, which remains inert.
No workers, execution relays, scheduler timers, outcome/retry/cancel producers,
cancellation/manual retry APIs, snapshots, manifests, retention, repair,
acknowledgement sidecars, watermarks, batching or Phase 6 controls were added.

## Created and modified files

Modified existing files (six):

```text
README.md
docs/architecture.md
lib/tay.ex
lib/tay/job.ex
lib/tay/worker.ex
lib/tay/storage/writer.ex
```

Created source files (16):

```text
lib/tay/event.ex
lib/tay/event/value.ex
lib/tay/event/v1.ex
lib/tay/job_id.ex
lib/tay/error.ex
lib/tay/state/transition.ex
lib/tay/state/projection.ex
lib/tay/state/job_index.ex
lib/tay/state/queue_index.ex
lib/tay/state/scheduler_index.ex
lib/tay/engine.ex
lib/tay/engine/config.ex
lib/tay/engine/supervisor.ex
lib/tay/engine/lifecycle.ex
lib/tay/engine/admission.ex
lib/tay/storage.ex
```

Created test/support files (17):

```text
test/support/event_helpers.ex
test/support/engine_helpers.ex
test/tay/event/codec_test.exs
test/tay/event/atom_independence_test.exs
test/tay/state/transition_test.exs
test/tay/state/recovery_test.exs
test/tay/state/projection_test.exs
test/tay/state/generated_model_test.exs
test/tay/engine/initialization_test.exs
test/tay/engine/job_builder_test.exs
test/tay/engine/admission_test.exs
test/tay/engine/core_test.exs
test/tay/engine/config_test.exs
test/tay/engine/lifecycle_test.exs
test/tay/engine/fault_test.exs
test/tay/engine/capacity_test.exs
test/tay/engine/large_recovery_test.exs
```

Created fixture files (52): every one of the 50 filenames listed in the hash
inventory below, under `test/fixtures/events/v1/`, plus that directory's
`README.md` and `SHA256SUMS`. Hex files are literal byte containers, not
encoder-generated replacements. Created documentation: this file,
`docs/phase-4-implementation-report.md`. Total: 86 created files.

Existing Phase 1–3 source outside the additive Writer changes, native C/protocol,
tests, helpers, binary fixtures, RFCs/reports, application/configuration modules,
Mix/dependency files and TAY_PLAN were not edited. No existing test was weakened,
deleted or rewritten.

## Implementation boundaries and guarantees

- Record remains a registry-free physical codec. Event capability is exact
  type/schema membership, never `schema <= latest`. Unknown semantic capability,
  malformed payload or invalid transition stops existing-only recovery.
- Value parsing is left-to-right, exact-consumption and budgeted before allocation;
  text is scalar-valid UTF-8 without normalization; map order is bytewise canonical.
  All finite float bits, including signed zeros/subnormals, are retained. Provider
  initialization checks representative runtime bit preservation.
- Job runtime structs are never persisted. Definitions are immutable independent
  string-keyed values. Opaque bytes occur only at the schema's 16-byte Job ID.
  Worker/queue keys are inert; no atom/module creation or persisted-name loading.
- Pure prepare/apply is shared by live insertion and full replay. Complete
  contiguous understood records replay irrespective of unknown prior ACKs.
  No registry, clock, randomness, ETS, worker callback or external I/O occurs in
  semantic reduction.
- Engine retains the same recovered Writer, native helper/Port and flock through
  activation and all live writes. It never falls back to raw Writer startup.
  Terminal activation grants no online Engine or mutation capability.
- ETS is private, unnamed, without heirs, owned by Engine and built only after
  activation. Allocation/construction/publication failures terminate the
  generation. The full candidate map is not retained beside live ETS.
- Insertion checks canonical same-ID definition first. Reconciliation does not
  append or consume sequence space, including under lowered insertion limits or
  missing mappings. Conflicts never overwrite. All new-insertion validation and
  state/headroom accounting precede append. Actual receipt coordinates and mode
  must match before binding the sequence, updating all indexes and replying.
- The guardian grants a monitored fixed slot before any argument-bearing request.
  Submit and caller DOWN reach that same recipient in signal order. Submitted
  permits survive timeout/death; no hidden unbounded waiter queue. Old tokens/
  generations cannot write. Status is a bounded stale-capable snapshot, not an
  authoritative job query. Job reads serialize through Engine.
- Writer emits bounded poison/closure notifications without Port/capability or
  payload data. Guardian closes readiness before cleanup and kills the entire
  index-owning generation. OTP does not restart Writer under old ETS. An explicit
  host-controlled whole-group restart is required.
- Initialize-only uses the unchanged bootstrap/genesis protocol. Existing STORE
  refuses without successor/Event creation; pre-existing empty root still needs
  explicit bootstrap intent. Recovery never initializes missing ownership objects.

### Operational accounting

Insertion option names, domains, defaults and cross-budget checks are exactly
appendix §F: payload 1,048,576 (1..16,777,216), args 262,144 (5..16,777,216),
`insert_value_depth` 32 and `insert_value_nodes` 10,000. These are not decoding
or physical-validity limits. No clamping occurs.

Recovery options/deadlines retain Phase 3 defaults. Candidate defaults are
100,000 jobs, 268,435,456 charged bytes and 2,000,000 charged nodes. Per-job charge
is `2 * canonical_definition_bytes + 64 * definition_nodes + 2048` bytes and
`definition_nodes + 64` nodes. Startup accounts for up to three charged views.
Checks precede candidate insertion/live append; decoded strings are detached
from discarded backing frames. These are conservative deterministic accounting
units, not an exact VM peak-RSS guarantee or a Phase 6 capacity claim.

Admission defaults are 64 slots, 67,108,864 bytes and a 5,000 ms finite caller
timeout. Each slot gets the floor of total bytes divided by slots; an insertion
request is charged canonical definition bytes + 256. A transport refusal remains
operational even for a schema-valid or already retained definition. The client
bounds/measures the definition before materializing/sending it; Engine applies
new-insertion limits after authoritative reconciliation and before creating the
Event payload. This preserves reconciliation under reduced insertion limits.

## Verification commands and results

All final matrix commands below exited 0. Native helper compilation continues to
use C11, warnings-as-errors and the existing compiler/native build task.

| Verification | Result |
| --- | --- |
| `mix format --check-formatted` | Passed |
| `mix compile --warnings-as-errors` | Passed, no warnings |
| `mix test --warnings-as-errors` — macOS | **349 passed: 15 properties + 334 tests; 12 skipped**; seed 436890; 41.1 s |
| macOS ASan/UBSan full suite | **349 passed: 15 properties + 334 tests; 12 skipped**; seed 253012; 44.2 s |
| Linux/Btrfs strict-sync-enabled full suite | **357 passed: 15 properties + 342 tests; 4 skipped**; seed 725621; 32.9 s |
| Linux/Btrfs ASan/UBSan full suite | **357 passed: 15 properties + 342 tests; 4 skipped**; seed 434008; 32.1 s |
| Opt-in host physical/recovery/production-candidate large tests | **4 passed**, seed 926598; 419.1 s |
| Linux strict-sync 10,000-job production candidate | **1 passed**, seed 32941; 6.0 s |
| Production build | `MIX_ENV=prod mix compile --warnings-as-errors` passed |
| Production mode/test-hook boundary | Passed: write mode and test hooks refused; fault injection API absent |
| Application startup | Passed: empty foundation supervisor; Engine status unavailable until explicitly started |
| `git diff --check` | Passed |
| Frozen source/test/fixture comparisons | Exit 0, no differences |
| Appendix-to-import literal byte comparison | **50/50 exact matches** |
| Event hash/frame tests | All 50 decoded-byte hashes match; all six exact physical frames encode/decode unchanged |

macOS toolchain: Darwin arm64, Elixir 1.20.2, Erlang/OTP 29 / ERTS 17.0.2.
Linux uses the existing `elixir:1.20.2` image. The actual Docker data volume was
explicitly checked with `stat -f` and returned **btrfs**. Sync tests use that
named local volume, not the source bind mount. A sync-enabled suite also includes
deliberate write-mode/unsupported-mode cases; “357” is not a claim that each
individual test performs a sync append.

The 12 macOS skips are eight unsupported strict-sync/platform cases and four
opt-in large cases. Linux skips only those four opt-in cases. The host large run
exercises all four separately: exact 1 GiB lazy physical geometry, real 1 GiB
existing-store replay/activation, 300 small segments, and 10,000 production
definitions. Linux additionally runs the new production-candidate test in sync
mode. No hardware power-cut simulation or XFS/ext-family qualification is claimed.

Exact matrix/platform commands:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized mix test --warnings-as-errors
docker run --rm --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data elixir:1.20.2 stat -f -c '%T' /tay-data
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 elixir:1.20.2 mix test --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build/sanitized-phase4 -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_NATIVE_SANITIZE=1 elixir:1.20.2 mix test --warnings-as-errors
TAY_LARGE_SEGMENT_TEST=1 TAY_LARGE_RECOVERY_TEST=1 mix test test/tay/storage/segment_large_test.exs test/tay/storage/recovery_large_test.exs test/tay/engine/large_recovery_test.exs --warnings-as-errors
docker run --rm --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -w /workspace -e MIX_BUILD_PATH=/tay-build -e MIX_HOME=/tay-build/mix -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 -e TAY_LARGE_RECOVERY_TEST=1 elixir:1.20.2 mix test test/tay/engine/large_recovery_test.exs --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix run -e 'IO.inspect(Supervisor.which_children(Tay.Supervisor)); IO.inspect(Tay.status())'
elixir -pa _build/prod/lib/tay/ebin -e 'for mod <- [Tay.Engine.Config, Tay.Storage.Writer], do: Code.ensure_loaded!(mod); {:error, _} = Tay.Engine.Config.new(data_dir: "tmp/prod-check-unused", durability: :write); {:error, _} = Tay.Engine.Config.new(data_dir: "tmp/prod-check-unused", test_hook: fn _ -> :ok end); false = function_exported?(Tay.Storage.Writer, :inject_fault, 6); IO.puts("production refuses write mode and test hooks; no fault API")'
```

Startup output was `[]`, followed by
`%{state: :unavailable, freshness: :bounded_snapshot}`; it did not open storage.

### Incremental verification and corrected development failures

Focused tests ran during every slice rather than being deferred to the matrix:

| Exact command | Checkpoint result |
| --- | --- |
| `mix test test/tay/event --warnings-as-errors` | 9 passed initially, including 2 properties |
| `mix test test/tay/event test/tay/state --warnings-as-errors` | 16 passed after pure model; later 21 after recovery/index tests |
| `mix test test/tay/event test/tay/state test/tay/engine --warnings-as-errors` | 25 passed at initialization/lifecycle slice; later 36 at core/admission |
| `mix test test/tay/storage --warnings-as-errors` | Unchanged regressions: 257 passed, 10 skipped; seed 963153 |
| `mix test test/tay/state/generated_model_test.exs --warnings-as-errors` | 1 property passed, 40 generated full histories; seed 559850 |
| `mix test test/tay/engine/fault_test.exs test/tay/state/projection_test.exs --warnings-as-errors` | 25 passed, 1 sync skip; seed 449889 |
| `mix test test/tay/event test/tay/engine/job_builder_test.exs --warnings-as-errors` | Final focused codec/builder run: 13 passed, 2 properties; seed 284718 |

Development iterations corrected a Kernel `apply/2` import conflict, new-test
helper/expectation mistakes, warnings from constant comparisons/unused aliases,
and one test incorrectly expecting an immediately fresh guardian counter.
The first host full run had 343/344 passing because the new restart test helper
did not unwrap OTP's nested `ownership_busy` result. Its bounded **test-only**
eventual-release assertion now recognizes that wrapper and retries only that
ownership diagnosis. Production startup still fails closed and never retries.
No legacy tests/helpers were changed. The large run emitted an unused-alias
warning during compilation; that alias was removed before the final clean
compilation and matrix. Its four tests and exit status were successful.

Initial sandbox attempts at the large/startup/production-build commands failed
before tests with Mix local TCP-lock `:eperm`; the same commands were rerun with
explicitly granted permissions. These were environment failures, not test skips.

## Fault, adversarial and resource coverage

| Boundary/scenario | Assertion |
| --- | --- |
| Before append | Submitted caller gets unknown after Engine loss; no job in recovered history |
| Native write error, partial write, crash after full write | No false success; exact evidence preserved; full record replays, partial record refuses activation |
| Complete write then sync failure (Linux) | Generation revoked; complete understood record participates after restart despite missing ACK |
| Matching receipt / pre-projection | Committed event survives Engine death; no stale view |
| Each old-key removal, JobIndex write and secondary-key write | No partial public state; every private table dies with Engine; full replay restores effect |
| Each of three index allocations, index loading, pre-ready publication | No readiness after failure; post-activation failure is not misclassified as pre-activation preservation |
| Pre-reply, timeout after append, post-success reply before permit completion | Stable unknown-outcome reconciliation; observed success survives restart; no duplicate event |
| Helper death / poisoned-but-alive Writer / Writer death / guardian death | Gate closes and all indexes are revoked; no independent Writer restart |
| Reserved/submitted caller death, timeout, abandoned pre-grant claim | Only safely unused capacity is reclaimed; submitted work retains its slot |
| Byte/count saturation, stale tokens/generations | No payload before reservation, no unbounded waiter queue, no old-generation append |
| Missing root, corrupt/short tail, unknown semantics, invalid transition | Existing-only failure; byte/namespace snapshots unchanged; no false not-found/readiness |
| Candidate jobs/bytes/nodes and decode budgets | Retryable operational refusal before activation; larger budget succeeds on unchanged history |
| New-insertion payload/args/state budgets | Refusal before I/O, healthy generation retained; same-ID comparison occurs first |
| Sequence/segment exhaustion | Pure terminal-capability check and injected near-limit headroom model refuse without wrap/write |
| Numeric/UTF-8/schema boundaries | Literal hashes, all unknown tags, all literal-payload truncations, extra/missing keys, exact consumption, ETF-looking bytes, ±0/int identity |
| Atom/module independence | Fresh VM decodes a previously unknown module-looking UTF-8 key without interning/loading it |
| Generated lifecycle/index oracle | Independent state/index expectations after each event; all six types, revisions, attempts, interrupts, terminal/manual retry paths, live/wire/full-recovery equality |
| Rotation and retained history | Sixteen 1 MiB-argument insertions cross the minimum rotation target; exact receipts and restart equivalence verified |
| Large operational envelope | Real 1 GiB bounded traversal plus 10,000 definitions; too-small retained-job budget preserves history then succeeds when raised |

Coordinate exhaustion uses explicit arithmetic/model tests; it is not a claim
to have materialized 2^64 historical records or segments. Native protocol and
Phase 1–3 bootstrap/rotation/lifecycle adversarial suites run unchanged in every
full matrix, including both sanitizer builds. No ASan/UBSan findings occurred.

## Fixture and frozen-contract evidence

All 46 tracked legacy fixture files remain byte-identical: 18 Record binary
fixtures, 22 Segment/STORE binary artifacts and six supporting files. The SHA-256
of their ordered complete hash listing is unchanged:

`ecab6df7e7bd5215c1f85daee397ab484bb7a23cce90941fb9c77d28267b1004`

```sh
git ls-files -z test/fixtures/storage | xargs -0 shasum -a 256 | shasum -a 256
git diff --exit-code -- lib/tay/storage/record.ex lib/tay/storage/crc32c.ex lib/tay/storage/segment.ex lib/tay/storage/reader.ex lib/tay/storage/native.ex lib/tay/storage/recovery.ex lib/tay/storage/recovery c_src test/fixtures/storage test/tay/storage test/support/record_helpers.ex test/support/segment_helpers.ex test/support/native_helpers.ex test/support/recovery_helpers.ex mix.exs mix.lock config lib/tay/application.ex lib/tay/config.ex
git diff --exit-code -- docs/phase-1-storage-format-rfc.md docs/phase-2-segment-format-rotation-rfc.md docs/phase-3-recovery-rfc.md docs/phase-1-implementation-report.md docs/phase-2-implementation-report.md docs/phase-3-implementation-report.md test
git diff --check
```

Record v1 is still a 24-byte header/28-byte overhead with unchanged CRC32C and
16 MiB payload maximum. STORE remains 28 bytes; Segment remains 44-byte header,
64-byte footer, 1 GiB maximum with identical naming, checksum and topology rules.
No native opcode, physical parser/accumulator, durability barrier, payload hash,
Event field/enum/policy constant or compatibility rule was changed.

All 50 new literal vectors were imported directly from the approved appendix,
not recalculated by the implementation. This independent read-only comparison
returned “50/50 literal byte vectors match the approved appendix exactly”:

```sh
ruby -rdigest -e 's = File.read("docs/event-v1-contract-appendix.md"); vectors = {}; s.scan(/^#### ([EN][0-9]+)\n\n```hex\n(.*?)```/m) { |id, hex| vectors[id] = hex.gsub(/\s/, "") }; s.scan(/^\| ([VX][0-9]+)[^\n]*?\| `([0-9a-f]+)` \| `([0-9a-f]{64})` \|/) { |id, hex, hash| vectors[id] = hex }; abort "wrong count" unless vectors.size == 50; vectors.each { |id, hex| actual = File.read("test/fixtures/events/v1/#{id}.hex").gsub(/\s/, ""); abort id unless actual == hex }; puts "50/50 literal byte vectors match the approved appendix exactly"'
shasum -a 256 test/fixtures/events/v1/SHA256SUMS
```

Manifest-file SHA-256:
`092abb6de9965b1077edd88e4316d89474595fb2500a0783b920ba440b3cbae0`.

The following hashes are of **decoded literal bytes**, not the hex text. Every
listed file is under `test/fixtures/events/v1/`:

```text
1b59a812f2b2129532a243c4586f5c8a7702ab99550e6593495715a0c111280e  E1.hex
54c6cac6d57c283e777c1d85621589f8234ec4d786766488b36d604ca67a6a06  E2.hex
d1097553e8e4201339b9fbab03425523d2e49b8f6d7e0d59b9596c3872b9540f  E3.hex
1884923c049b0500e4e61872b09285c68f1bbc715cd00448edbf8f6d0a1db73a  E4.hex
999d5dd5da12cb2b80070ea90fe60c8eec97112e1cffe8d236e5ef8da7f3d757  E5.hex
bb31c3ba2edb45900164723f1150d13b4418540387f04ad57b3732fcd04d0a5f  E6.hex
26f3545dc521d5ba729bf92b4481b556328c0b8f72e2e78db4e40c49a39b6322  N1.hex
b859ceb3992994625036a8c8a9fa4fe360b915763290d153eece1748085057aa  N2.hex
de2aeb86de0b0d8ab2d688da5642fa03c5e8c4402a5fd21543718d6cb8b4097d  N3.hex
01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b  N4.hex
9fa25a51b7ae4c7d0f299364438645d966dea307198298e798cfecd998fccd74  N5.hex
e0f9b1bf36631eed069470ff227586a246e81ed58f94f909d908fafade719de6  N6.hex
a75272200392f635206e5dddab74d0f92fcd216d44e70caea0982f06a28ca26f  N7.hex
7dd7f3353146649a5587303862d44c94f8425aa5536e439b7d72d0af2e4456b8  N8.hex
6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d  V00.hex
4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a  V01.hex
dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986  V02.hex
b9b8f72be2eec31d908160bfcfc8b04e118eca731888b43b6b842c4267c1fc3c  V03.hex
339eed010a5e07b4314cb00f1234d636dc30df8fce73917165c299c6b4811804  V04.hex
93e60f669b99ad3e3ee6284b139e57adfb419960f390858e46ea565bbf82d001  V05.hex
9a6d8f59e9688e6298a6457011969ca598f6bd3e154a746c22a299fca5a87a5e  V06.hex
15c9b5d13d99e2afce728fca9de0850dd4cfe63a5318ac6cd9ff94b1dca87ff7  V07.hex
0806653bb73f9922b047d694edd1750c506c086957c9ee0608ddd1856d207de5  V08.hex
6c449f91c1adbf3945ad078f5f875c0c1f133f246c4588668faffbe23a3c195f  V09.hex
b7d0a547dfa7ddb4df0b4b3d5f5cd0f127273a9cc78246a6a595e9bca208701a  V10.hex
d85eec32b8bc9d775c7ebd03d8bcea24e38f2e5301c1bfc632357dede779e736  V11.hex
a011061167419227d27191bcfecb53baee0b76a98334b8b65bcbf6b3fea28f6d  V12.hex
e81302fd36fc158d3d978ca808d262cfa7667c3e1784f59c9bdddac976a1ca05  V13.hex
b45482224b439a3d548c65378929b7dcc16a42288530b7b20d5c8103cc879d10  V14.hex
06c4df6668e142864ca3ea31637eb5dbd76d36115399f581249648f8855acae2  V15.hex
28b0c37fcc9587b46c38e8da4f697dd3a6645df0f31bd9e0d87a11f3cae5663d  V16.hex
e3675b08b81dcf18ccf60c614161a6436ae48a537bde9bd825b5a2af092f2167  V17.hex
087317a4e64aab78e69e6bfff106d03969dba6ebc3cd425372fb02a9179a3ca9  V18.hex
bdbd1b7f7d4b30925d7109e134d3a0666e68e8a341647ba19f808ea1fb42d17d  V19.hex
2d4e31303a612040d7976c45a1e46dee1b57b5028a2c66015021880bd0c9f41f  V20.hex
18b1b592a44f7fbe33dab6a3d22857eea5118da14d6fabbc59b0681dbf1286f1  V21.hex
ceba8e226fc1ae3ed6e6fd58d778d4365556868b78faf5e5abbab0c04e0bd392  V22.hex
d7a1109d4371820092ee5b393b6d03a58f7a099bb67c45e8b458c8189a299823  V23.hex
df2559a785501c923fbed9a412d4cd32828c46b3d361ad7a10cd507fd755a86f  V24.hex
dc4c8669df128318c5790c414c870cc76c585268552851e78d3ee8604dbec0e3  X01.hex
58201ed1c77965aa3f7598c5effa9c8d67aca7c5273c0d803ab01e9f2e3e5720  X02.hex
1e334b0078af795f8b546ca71463f6cac4e364f469acb490780e915e8deff861  X03.hex
6572a1f198cf80b8db5deb91f05e19ccea044782d3937518a3328594832f95a5  X04.hex
65defe900139cee0857930a1124488394cc54a711692ed11c5ff4858cc73a55a  X05.hex
6bd86c80a0f9334c97302f1b6b503d9a2e9231ee5a436ff5c5aa2f3675e10b6f  X06.hex
1863998c3f504c7a056a637d44f28865733bfcf2a228004895a47f1d4e592b98  X07.hex
bab55a4d73a9a687335c193cf1fbf33331b4a15c89214b0d0c5a3ab0aece7f4e  X08.hex
c0ba8a33ac67f44abff5984dfbb6f56c46b880ac2b86e1f23e7fa9c402c53ae7  X09.hex
865566bb05a165ddedd5df5f4b86ef694a243022387d6af35d39a1dfe6e7421b  X10.hex
1d96f47b3a65ac17196e57f3bb919a35701c7fda77c67a5021c2c822d11eec99  X11.hex
```

## Deviations, correctness concerns and remaining limitations

No approved long-lived contract contradiction or required format change was
discovered. There are no RFC/byte-contract deviations. Hex containers preserve
the approved bytes exactly and are decoded only by test fixture readers.
Existing physical tests/fixtures remain untouched.

Known boundaries, not new guarantees:

- Incomplete canonical tails remain non-destructively unavailable. All evidence
  is preserved; no automatic writable repair or sequence reuse exists.
- A submitted operation may commit after caller timeout/death. Neither successful
  replay nor same-ID reconciliation proves a previous ACK or exactly-once effects.
- Native closure/flock release can finish asynchronously. A fresh startup may
  briefly refuse `ownership_busy`; do not delete locks or automatically retry
  uncertain writes. Test helpers wait only for known ownership contention.
- Candidate/startup/transport accounting bounds the cooperative protocol, not all
  shared-BEAM allocations, hostile messages, arbitrary caller exit reasons or
  exact RSS. Live status counters can lag. Hot code replacement is unsupported:
  stop the whole Engine and perform fresh recovery for semantic-code changes.
- Maximum-coordinate cases are modeled; hardware power loss, other filesystems,
  deployment packaging/capacity SLOs and the final production release gate R5
  remain Phase 6 work.
- Retained-job storage is finite and there is no retention/compaction. Same-ID
  reconciliation currently relies on retained immutable definitions.
- Mix version remains the baseline `0.1.0-dev`; release/version packaging and
  tags were not changed by this implementation.
- Phase 5 must add actual execution, interrupted-execution reconciliation,
  scheduling, outcomes, cancellation and manual retry using this existing model.
  None is exposed as a hidden or feature-flagged implementation here.

Stop point: Phase 4 only. No Phase 5 implementation is authorized or started.

