# Store-v2 compaction Phase B implementation report

Status: **in progress, not qualified for authority publication or use**. Phase B
must not be represented as complete. Phase C has not begun.

## Current continuation (not yet an enabled Store-v2 path)

The lock-owning native helper now has pinned `epochs/`, selected-epoch and
private-candidate descriptors; narrow operations create a candidate with its
`segments/`, publish a completed epoch directory, move V1 canonical segments
to a preserved legacy name, replace CURRENT with an identity-checked staged
76-byte pointer, report filesystem headroom, and select an epoch for reopening.
The Elixir Native wrapper exposes these operations. An integration test builds
an empty sealed-base/active-tail shape, writes and syncs a manifest and marker,
publishes CURRENT under the same lock, verifies old V1 topology is unreadable,
and reopens the selected epoch. This tests helper mechanics, not the full
candidate semantic gate or lifecycle protocol. No production compaction call
uses these new operations yet. Native sanitizers and exhaustive fault injection
are now mandatory before qualification.

The V1 reader treats only the reserved `epochs/` directory as nonauthoritative
staging while V1 `segments/` remains present; it still refuses `STORE-V2` or
`CURRENT`. First adoption now durably publishes an exact, checksummed
`ADOPTION` rollback intent before moving the V1 `segments/` directory. If an
interruption occurs before CURRENT exists, the same lock-owning native helper
can restore that exact legacy directory, sync both parents, remove any
pre-pointer `STORE-V2` marker, sync root, then remove the intent and sync root.
If CURRENT exists, native rollback refuses. Writer startup now invokes this
same-lock reconciliation before V1/V2 selection. A focused test exercises
restart after the move and marker publication and proves V1 preflight succeeds
after reconciliation. Restore/unlink/fsync fault qualification remains.

The activated Writer can now invoke the streaming Publisher after sealing its
source frontier. V1 is re-replayed through the V1/V2 migration oracle under the
lock; V2 is independently re-replayed from the selected epoch. A successful
publisher fences further appends pending a generation restart. Store-v2 startup
replays the selected immutable base and mutable tail under the same lock and
revalidates a frozen view before activating writes. Engine emits type-8 V2
mutations, preserves logical revision and global availability order, and emits
epoch-scoped public handles. The Lifecycle guardian now owns a single manual
compaction operation, closes admission, drains execution, and restarts the
generation after verified publication. An end-to-end V1 adoption, V2 mutation,
second compaction, and recovery test passes. Deferred reclamation, thorough
fault qualification, publication-unknown reconciliation, and large workloads
remain; this is not yet Phase-B complete.

## Implemented and exercised

* `lib/tay/storage/v2/authority.ex` defines checksummed `STORE-V2`, `CURRENT`
  and immutable manifest metadata, exact-field decoding, SHA256 pointer binding,
  topology checks and single-authority selection validation.
* `lib/tay/storage/v2/v1_migration.ex` projects a validated, physically
  consecutive V1 event stream into V2 logical revisions/tokens, durable global
  availability order and canonical terminal timestamps. It runs V1 and V2 pure
  reducers in tandem and checks common durable state after each transition.
* `lib/tay/storage/v2/epoch.ex` builds sealed snapshot-base segments plus an
  empty active tail using unchanged Record-v1/Segment-v1 codecs. It independently
  parses, replays and semantically compares supplied bytes before returning a
  candidate. It also replays post-snapshot V2 mutation records. This path is
  pure/in-memory qualification, **not** a native-owner filesystem publisher.
* `lib/tay/storage/reader.ex` now refuses a root containing `STORE-V2` or
  `CURRENT` in both V1 preflight and V1 physical inspection, including a
  partially adopted root. Untouched V1 recovery remains accepted.
* `lib/tay/storage/v2/publisher.ex` is a production-shaped streaming candidate
  writer: it estimates space, writes one snapshot Record at a time to sealed
  bases, writes a header-only tail and synced manifest, independently replays
  before and after epoch rename, and stages/replaces CURRENT. Its direct native
  first-adoption and repeat-publication smoke tests pass; it is not yet invoked
  by Writer/Lifecycle and therefore is not enabled for users.
* `test/tay/storage/v2_authority_test.exs`, `v2_v1_migration_test.exs`,
  `v2_epoch_test.exs` and `v2_refusal_test.exs` exercise those slices. Phase-A
  code/tests, the seven literal V2 Record frames in
  `test/fixtures/storage/v2/records.hex`, and
  `docs/storage-compaction-rfc.md` were also continued. The Phase-A report
  inventories its modules/tests and the approved availability/terminal fixes.

`STORE-V2`: `"TAY2"[4] || version=1[1] || reserved=0[3] || STORE_ID[16] ||
CRC32C[4]`, exactly 28 bytes. `CURRENT`: `"TAYC"[4] || version=1[1] ||
reserved=0[3] || STORE_ID[16] || epoch_id[16] ||
SHA256(manifest bytes)[32] || CRC32C[4]`, exactly 76 bytes. Manifest:
`"TAYM"[4] || version=1[1] || reserved=0[3] || Value-body-length[4] ||
canonical exact-key Value map || CRC32C[4]`. The map identifies the source
frontier/epoch, captured policy/time, ordered source segment digests, sealed
base segment IDs/first and last physical sequences/byte lengths/digests, and
designated tail ID/first sequence. Record payload layouts and the global
`availability_order`/`terminal_at` changes are exact in the Phase-A report.

Complete worktree inventory for this implementation checkpoint:

* `docs/storage-compaction-rfc.md`
* `docs/phase-a-compaction-implementation-report.md`
* `docs/phase-b-compaction-implementation-report.md`
* `lib/tay/storage/reader.ex`
* `lib/tay/storage/native.ex`
* `c_src/tay_storage_helper.c`
* `lib/tay/storage/v2/authority.ex`
* `lib/tay/storage/v2/publisher.ex`
* `lib/tay/storage/v2/reader.ex`
* `lib/tay/storage/writer.ex`
* `lib/tay/engine.ex`
* `lib/tay/engine/lifecycle.ex`
* `lib/tay/engine/operations.ex`
* `lib/tay/job.ex`
* `lib/tay/state/queue_index.ex`
* `lib/tay/state/task_index.ex`
* `lib/tay.ex`
* `lib/tay/storage/v2/codec.ex`
* `lib/tay/storage/v2/epoch.ex`
* `lib/tay/storage/v2/reducer.ex`
* `lib/tay/storage/v2/snapshot.ex`
* `lib/tay/storage/v2/v1_migration.ex`
* `test/fixtures/storage/v2/README.md`
* `test/fixtures/storage/v2/records.hex`
* `test/tay/storage/v2_authority_test.exs`
* `test/tay/storage/v2_epoch_test.exs`
* `test/tay/storage/v2_phase_a_test.exs`
* `test/tay/storage/v2_property_test.exs`
* `test/tay/storage/v2_refusal_test.exs`
* `test/tay/storage/v2_v1_migration_test.exs`
* `test/tay/storage/v2_native_test.exs`
* `test/tay/engine/compaction_test.exs`

## Qualification so far

Before the native continuation, on macOS `mix format --check-formatted`,
`mix compile --warnings-as-errors`, and the focused V2 test files passed. The
last pre-native focused command
`mix test test/tay/storage/v2_phase_a_test.exs
test/tay/storage/v2_property_test.exs test/tay/storage/v2_epoch_test.exs
--warnings-as-errors` passed 18 (three properties, 15 examples), ExUnit seed
`611969`. The final full `mix test --warnings-as-errors` run passed 595
(22 properties, 573 tests), 14 skipped, seed `711910`.
An explicit frozen Record/Segment and V2 fixture command,
`mix test test/tay/storage/record_fixture_test.exs
test/tay/storage/segment_codec_test.exs test/tay/storage/v2_phase_a_test.exs
--warnings-as-errors`, passed 37, seed `710075`.
The new `v2_native_test.exs` native/Writer/Engine cases passed (six tests, seed
`29515`). The end-to-end manual, repeated-compaction and restart case passed
(one test, seed `913747`). V1 lifecycle/admission/public mutation regression
tests passed (15 tests, seed `681827`). No
Linux/Btrfs strict-sync run has been performed. Native helper code has now
changed; ASan/UBSan qualification remains outstanding. No authoritative
compaction run has occurred: stop-the-world pause and candidate disk
amplification cannot be measured yet.

## Required before Phase B can pass

Deferred unlink/reclamation and startup cleanup are not yet implemented.
Publication-unknown/lost-reply reconciliation is not yet complete. The native
helper still lacks per-fsync/fault-site coverage for every durable boundary;
the physical crash matrix, disk-full/short-write tests, post-publication
failure tests, native sanitizers, 10,000-job/1 GiB and Linux/Btrfs
qualification remain. Disk admission estimates candidate bytes and checks
`fstatvfs` plus 64 MiB headroom, but its conservative source-plus-candidate
amplification and resource/deadline bounds have not been fully qualified.
Measure pause, source/candidate bytes, peak disk amplification, construction
memory and reclaimed bytes on realistic workloads. The production Publisher
streams individual snapshot records; it does not call the pure in-memory Epoch
builder.

An old binary cannot inspect `STORE-V2`/`CURRENT`; it only sees the old root
`segments/` topology. First V1-to-V2 adoption must prove that canonical V1
segments are no longer old-binary-readable after publication, while preserving
source bytes and automatic same-lock rollback/recovery at every pre-CURRENT
crash boundary.
Metadata decoding or the new-binary V1 reader guard alone cannot prove this.
No migration/publication code has been enabled without that proof.

There is no released-format deviation: the metadata layout above fixes fields
the RFC had left abstract, and the two approved Store-v2 format corrections
precede release. Frozen Store-v1 bytes remain untouched. Do **not** proceed to
Phase C or deploy Store-v2 compaction from this checkpoint.
