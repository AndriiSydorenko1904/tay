# RFC: Phase 3 recovery, semantic replay, and writer activation

Status: **APPROVED DESIGN — G1–G6 resolved; no implementation authorized.**
Date: 2026-09-12.
Inspected baseline: `6743ea488e52200d79416470f1329ea013ee6c16`
(`Implement Phase 2 durable segment storage`), initially clean worktree.

## 1. Normative design and implementation boundary

The user's G1–G6 approvals are binding and are recorded in §19. Requirements in
this RFC govern the future Phase 3 implementation; they are not optional design
suggestions. Design approval does not authorize source implementation, which
requires a separate user instruction.

Retain Record v1 and Segment/STORE v1 unchanged. Add a bounded recovery
coordinator that runs inside the existing storage owner, under one continuously
held native lock, with three deliberately separate results:

```text
physical inspection of the entire store
    -> semantic replay into private candidate state
    -> revalidation and Phase 2 writer activation
```

No queues, insertion API, ETS indexes, job transitions, payload encoding, snapshot,
manifest or destructive repair are permitted in this phase.
An injectable semantic-decoder contract is required; production Event meanings
and serialization still require their own approval. Physical-only inspection
must never masquerade as normal semantic recovery.

**Approved tail policy: preserve all evidence and refuse writable activation.**
Precisely diagnose every incomplete Record, footer or canonical suffix. No
automatic truncation, padding, deletion, rename-aside, sequence reuse or suffix
repair is permitted. No partial recovered state may be published.

The reconciled Phase 3 exit criterion “incomplete active tail recovers safely”
means:

> an incomplete active tail is detected safely, preserves all evidence, never publishes partial recovered state, never reuses occupied/ambiguous sequence space, and refuses writable activation.

It does **not** mean automatic destructive repair or automatic writable restart.
A fully valid history must recover automatically through the configured semantic
provider and activation gates; every complete, physically valid, contiguous and
semantically understood event participates regardless of unknown prior caller
acknowledgement. Recovery does not establish that the caller observed success
and does not provide exactly-once semantics.

Automatic torn-tail repair is deferred to a future separately reviewed
recovery/repair protocol. No acknowledgement metadata, repair journal, watermark
or format change is introduced in Phase 3. The alternatives in §6 are retained
as design input, not implementation options or unresolved Phase 3 gates.

## 2. Authority and source reconciliation

Read completely for this review:

- [TAY_PLAN.md](../TAY_PLAN.md), especially §§9–12, 20–25, 32–35, 38 and Phase 3.
- [Approved Phase 1 storage RFC](phase-1-storage-format-rfc.md) and
  [implementation report](phase-1-implementation-report.md).
- [Approved Phase 2 segment/rotation RFC](phase-2-segment-format-rotation-rfc.md),
  [implementation report](phase-2-implementation-report.md), and
  [implementation-gate reconciliation](phase-2-implementation-decomposition.md).
- [Accepted adversarial requirements](phase-1-review-input.md) and
  [storage design input](storage-rfc-input.md).
- [Current architecture](architecture.md) and
  [native protocol/platform notes](../c_src/README.md).

The Phase 2 RFC still contains historical “proposed/no implementation authorized”
wording. The user's subsequent approval, accepted implementation and gate
reconciliation establish its authority; this RFC does not edit that historical
document. Likewise, the Phase 1 RFC's candidate 32-byte segment discussion and
the original 16-digit filename illustrations are superseded by approved Phase 2.
The accepted review's no-skipping/no-implicit-repair requirements remain binding.
Reports are implementation evidence, not permission to override normative rules.

The subsequent G1–G6 approvals resolve this RFC's original review gates. The
Phase 3 entry and §12 of TAY_PLAN.md are reconciled with the binding fail-closed
tail interpretation; the roadmap no longer authorizes optional Phase 3 repair.
No Phase 1 or Phase 2 byte contract is amended by this reconciliation.

## 3. Exact roadmap scope

The Phase 3 entry names **`Tay.Storage.Recovery`** and assigns:

| Roadmap responsibility | Approved Phase 3 disposition |
| --- | --- |
| Discover segments | Reuse and expose safe locked discovery; never infer a new store during recovery |
| Validate ordering | Require the existing ID-1/sequence-1 anchor, complete topology and continuity |
| Replay records | Physical preflight, then mandatory semantic gate, then ordered private reduction |
| Diagnose incomplete Record/footer/canonical suffix | Preserve every byte, publish no partial recovered state and refuse writable activation; classification is never repair authorization |
| Distinguish corruption | Preserve physical, semantic, operational, resource and uncertainty classes |
| Preserve incomplete tails without repair | No truncation, padding, deletion, rename-aside, sequence reuse or suffix repair; automatic repair is a future separately reviewed protocol |
| Produce replay stream/state input | Bounded synchronous reduction with all-or-error result; no public lazy stream that can hide a bad suffix |

The six explicit roadmap scenarios remain required: clean records; partial
header/payload/checksum at EOF; bad checksum; corruption before later records.
The first must replay automatically when semantically understood, within the
operational preconditions and budgets. The next three must fail closed with
precise diagnosis, preserved evidence, no partial recovered state and no writable
activation. They are not evidence of a permissible destructive operation. The
last two fail as corruption. Partial footer and other canonical suffix cases
are additionally mandatory (§16–17).

Phase 4 owns concrete projection/ETS/state-transition rules. Phase 5 owns
insertion acknowledgement and job IDs. Later phases own execution, retries,
scheduled/cancelled job behavior, and snapshot/compaction protocols. The general
startup narrative in plan §12 does not pull all of those into Phase 3.

## 4. What the current implementation establishes — and does not

Source locations below refer to the inspected baseline, not future code.

| Existing component | Safe foundation | Required integration work / limitation |
| --- | --- | --- |
| `Record.decode/1,2`, `record.ex:126` | Exact one-frame consumption; CRC before length; independent decode budget; assignable unknown semantics accepted | Never interpret its `:ok` as Event acceptance |
| `CRC32C`, `crc32c.ex` | Approved pure algorithm and raw incremental state | No native replacement or checksum-contract change |
| `Segment`, `segment.ex:89` | Fixed envelope codecs, filenames, physical bounds and parser delegation | No persisted/runtime coupling; existing return contracts remain physical |
| `Segment.Parser`, `parser.ex:195,217,262` | Bounded positional reads; individual sequence checks; final footer/segment verification | Reducer runs before final segment/footer validation; callback result is just an accumulator, not a halt/error instruction |
| `Reader.inspect_store/1`, `reader.ex:12` | Locked complete discovery, marker, all segment scans and topology | Monolithic successful-store path returns summaries, not semantic readiness; no caller resource-options API |
| `Reader.reduce/3`, `reader.ex:26` | Physical preflight before a second bounded pass | Reducer receives Record/file offset, not full store/segment coordinate; no explicit semantic halt; calls `inspect_store` again |
| `Reader.with_file`, `reader.ex:126` | Opened identity/extent compared to discovered file and checked on close | No `try/after` around arbitrary callbacks; exception-safe descriptor cleanup is needed for a reusable halted pass |
| `Reader.initialized`, `reader.ex:77` | Marker validation is present | Unsupported STORE reasons are nested inside outer `:corrupt_store`; Recovery must preserve/normalize the underlying unsupported category |
| `Writer.init/1`, `writer.ex:38,193,423` | One temporary owner, existing bootstrap and activation protocols | It can bootstrap, sync, or create a highest-sealed successor before any Event gate; not a normal recovery entry point |
| `Native.open/2`, `native.ex:30`; C `acquire`, line 205 | Exclusive OS lock, pinned FDs, all writes native, strict uncertainty handling | Acquisition can create directories/lock and sync ancestors before inspecting semantics; it is not side-effect-free inspection |
| C `validate_read` / `check_paths`, lines 271 / 151 | Inode/path/link/extent checks around reads and commands | Same-inode/same-size content rewrites are not detected by stat alone; neither lock nor CRC is an adversarial security boundary |
| C listing, line 237 | Bounded packet; no partial successful listing on overflow | Directory entries are materialized; memory is O(entry count), not constant for an arbitrarily large store |
| Application/Supervisor/Config | Explicit production path; empty root; no fake recovery readiness | Keep root empty in Phase 3; normal engine wiring awaits Event/projection approval |

One read-only probe against the existing built Segment code returned overall
physical success and visited sequences 1, 2 and 3 even when the reducer returned
`{:error, :semantic_stop}` at every record (§20). That is consistent with the
current physical accumulator API, but proves that passing a tagged semantic
error into it is not a recovery stop mechanism. Do not “fix” this by changing
the meaning of existing arbitrary accumulators; add an explicit halt-aware API.

Existing Phase 1/2 fixtures and tests establish useful physical and syscall
behavior. Their historical passing counts are recorded in the reports; they
do not certify Event replay, repair authorization, or Phase 3 readiness.

## 5. Resolved ambiguities and binding scope decisions

| Issue | Dangerous implicit choice | Approved disposition |
| --- | --- | --- |
| Original “optionally truncate” versus “incomplete active tail recovers safely” | Treat `incomplete` as proof of a disposable append | G1 approved: detect safely, preserve all evidence, publish no partial state, never reuse occupied/ambiguous sequences, refuse writable activation; automatic repair deferred |
| No persisted acknowledgement frontier or historical durability mode | Infer `:sync` history from today's options or infer no ACK from a partial tail | Never infer either; preserving evidence is mandatory |
| Event serialization/registry is unassigned | Assign job event IDs or use ETF merely to make replay tests work | G2 approved: EventDecoder behaviour and test-only providers; separate Event RFC required for production semantics, not for implementing this phase's interface/tests |
| §12 mentions snapshots/ETS/dispatch | Load an unversioned snapshot, accept an arbitrary start offset, or begin Phase 4/6 | Replay from genesis only; no ETS/dispatch in Phase 3 |
| “Storage untouched” versus lock creation on inspection | Add a lock or sync unknown-semantic history before reporting unsupported | G3 approved: existing-only, non-publishing acquisition; missing lock is an operational ownership failure, never bootstrap permission |
| Writer already reports `:ready` | Use that physical state as permission to schedule jobs | G4 approved: same owner/helper/lock through replay and activation, private candidate and distinct post-activation admission reference; raw Writer remains physical tooling only |
| Complete record after failed sync/lost ACK | Drop it or reuse its sequence | G6 approved: replay every complete physically valid, contiguous, understood event and retain its occupied sequence; no prior-ACK or exactly-once claim |
| Highest sealed file has no successor | Create a successor before encountering an unsupported event in earlier history | Defer existing Phase 2 creation until full semantic validation/reduction succeeds |
| Unknown framing and unknown semantics | Treat both as “corruption we can repair” | Distinct stop classes; neither permits mutation |
| Lower configuration after restart | Use insertion/rotation limits to truncate historical bytes | G5 approved: fixed v1 limits; independent operational defaults and retryable resource failures on untouched storage |
| Future job state `executing` survives replay | Automatically reschedule, increment attempts or invoke worker modules now | Phase 4/6/7 must define shared transition and restart semantics; no invented transitions |

The approved design changes no stored byte and relaxes no corruption rule.
Existing-only recovery is an additive operational restriction on a new API,
not a new required field/file in the v1 physical format. A valid copied store
without its lock still has valid bytes; its inability to enter this stricter
API is `:ownership_unavailable`, not format corruption. Automatic lock recreation
with an inventory exception was not selected and is not authorized in Phase 3.

## 6. Failure model and repair authorization

### 6.1 Observations are not provenance

These two histories can leave identical bytes:

1. Append B after valid A, then crash before B is complete or acknowledged.
2. Complete and acknowledge B (possibly also later C), then lose/corrupt its
   suffix so the surviving bytes equal the same prefix of B.

For history 2, damaged framing plus matching/recomputed CRC can also claim a
length extending past EOF and hide later C inside that apparent partial body.
The fixed header CRC detects the approved length-only corruption case; it is
not proof against correlated corruption or a recomputed CRC. Searching for C's
magic would be unsafe because magic is allowed in payloads.

STORE identifies a store, not the last acknowledged sequence. An active segment
has no durable ACK marker; a highest segment without a complete footer cannot
prove it was never sealed. Filesystem type, current `:sync`, file timestamps,
stale PID/lock contents, and an error log do not resolve this ambiguity.

The Phase 2 strict contract rules out loss of acknowledged synced bytes only
under its stated honored-barrier assumptions. A valid CRC does not establish
that those assumptions held historically, nor that a damaged tail was produced
by the immediately preceding process. In write mode even an acknowledged tail
may have been lost. “Crash-only, intact committed prefix” would therefore be an
additional repair assumption, not a parser conclusion.

### 6.2 Proof obligations for any future destructive policy

All would need to hold, not merely the first two:

1. Exclusive ownership, stable identity/inventory, and fully validated preceding
   sealed history with genesis anchors.
2. Exact terminal object/boundary, within physical/resource limits; no subsequent
   canonical history, complete footer, or hidden required suffix being skipped.
3. Independent evidence that the range to discard contains no acknowledged or
   otherwise required complete event, under an explicitly approved failure model.
4. Mandatory semantic validation of all retained events; unknown partial semantics
   must not be converted into support or presumed safely discardable.
5. A target proof bound to current store ID, inode, extent, byte content and owner
   generation; not a caller-supplied offset or stale report from a previous lock.
6. A native-only mutation, verification, sync and crash-resumption protocol whose
   own interrupted execution cannot make lost data look like successful recovery.

Phase 1/2 bytes alone do not supply obligation 3 in the general damaged-tail
case. Nothing in this RFC grants a truncation certificate. The required action
for every nonempty incomplete canonical suffix is `:preserve_and_stop`.

### 6.3 Approved policy and deferred alternatives

Only alternative A is approved for Phase 3. B–E remain adversarial design input
for future separately reviewed work, not fallback branches in this phase.

| Alternative | Benefit | Risk / further decision |
| --- | --- | --- |
| A. Non-destructive replay and fail-closed tails (approved) | Preserves evidence and downgrade safety; no format change | No automatic writable recovery from incomplete Record/footer/canonical suffix; G1 explicitly accepts this availability limitation |
| B. Opt-in crash-only tail truncation | Better automatic restart availability without new bytes | Requires an explicitly narrower historical failure model; cannot distinguish the two histories above; unknown short headers remain especially problematic |
| C. Same-session trusted append evidence | Can distinguish some observed local failures | Lost on helper/BEAM death, does not solve general startup, and conflicts with Phase 2's poisoned/no-live-retry boundary unless separately reviewed |
| D. Durable independent intent/commit evidence | May support stronger bounded repair claims | New long-lived metadata/write-order/recovery protocol, backup/migration behavior and crash analysis required; a high-water mark alone cannot reconstruct lost bytes |
| E. Operator salvage/export to a separate store | May recover useful data for investigation | Not normal recovery, not automatic correctness, and not authorized or specified as tooling here |

Completing a torn footer, renaming a damaged canonical aside, padding bytes,
copying a good prefix over a file, or appending past an unresolved tail are also
repair/lifecycle decisions. None is permitted as a non-truncating workaround.
No `repair: true`, `force`, skip-unknown, rebase or arbitrary truncate-offset API
is permitted in Phase 3. Automatic torn-tail repair requires a future separately
reviewed recovery/repair protocol; do not add a best-effort branch, acknowledgement
metadata, repair journal, watermark or format change during this phase.

## 7. Responsibilities and ownership

`Tay.Storage.Recovery` is a synchronous coordinator/library, not another storage
GenServer. In an integrated session it executes inside `Tay.Storage.Writer`,
which already owns the Port. It neither owns a second lock nor transfers a Port
to another process. Tests may call it in a process owning an inspection-only Port.

| Component | Owns | Must not own/do |
| --- | --- | --- |
| Record / CRC32C | Existing framing and checksum contracts | Event registry, sequence allocation, repair |
| Segment / Parser | Exact bounded scan, envelope checks, physical traversal | Event interpretation, accepted projection checkpoints |
| Reader | Inventory, safe file scope, cross-segment validation, halt-aware physical traversal | Semantic policy, storage mutations |
| Recovery | Physical preflight, semantic ordering, private reduction, result/error normalization, replay-generation facts | Direct writable FDs, job state rules, serialization choices, destructive repair |
| Semantic codec provider | Explicit known types, supported schemas, full bounded payload decoding | Inferring support from disk, resolving/executing workers, skips or fallback |
| Pure consumer/reducer | Candidate state input; later a shared Phase 4 transition implementation | Dispatch, public ETS publication, filesystem/network side effects |
| Writer | Port lifecycle, activation gate, later serialized Phase 2 mutations | Treating physical-only inspection as semantic recovery |
| Native helper | Lock and all filesystem FDs; inspection/mutation command permissions; exact syscall results | CRC algorithms, Event support, deciding whether recovered state is semantically acceptable |
| Future engine owner | Final projection publication and dispatch barrier | Publishing partially recovered candidates |

Every cooperative writer, recovery process and maintenance operation uses the
same persistent lock inode. Hold it continuously across discovery, all passes,
candidate retention, activation, and subsequent writing. A report is not a lock.
Closing the helper after replay and opening a new Writer would create a race and
invalidate all activation authority. Independent offline inspection results are
never accepted as writer activation tickets.

Linux `flock` belongs to the open file description and is advisory; a new open
does not inherit ownership. This supports retaining the same helper, not a
release/reacquire handoff. [Linux flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html)
The approved no-Port-transfer design also avoids changing links and routing
pending replies between owners. OTP permits Port reassignment but does not make
it a storage handoff protocol. [OTP port_connect/2](https://www.erlang.org/doc/apps/erts/erlang.html#port_connect/2)

The embedding application and codec/reducer implementation are trusted code.
Owner checks and session references enforce correct cooperative API use; they
are not a sandbox against arbitrary code in the same BEAM. Native handles must
not be supplied to codec/reducer callbacks or published in recovery results.

## 8. Approved API contracts and exact consumption semantics

All APIs below are **approved internal design contracts**, not existing functions
or stable application APIs. No `Tay.recover/0`, `Tay.insert/1`, repair CLI or queue
API is added. Existing Record APIs and physical accumulator semantics remain
unchanged.

### 8.1 Recovery and physical traversal

```elixir
Recovery.inspect(native, options \\ [])
# {:ok, inspection} | {:error, recovery_error}

Recovery.replay(native, codec, initial_acc, reducer, options \\ [])
# {:ok, replay_result, candidate_acc} | {:error, recovery_error}

Reader.preflight(native, options \\ [])
# {:ok, physical_view} | {:error, physical_error}

Reader.reduce_while(native, physical_view, initial_acc, visitor, options \\ [])
# {:ok, final_acc} | {:error, traversal_error}
# visitor.(record, position, acc) -> {:cont, acc} | {:error, reason}
```

`inspect` performs full physical preflight only. It has no Event-success flag
and returns no activation capability. `replay` performs its own preflight under
the current inspection-only session, then a second bounded pass. It cannot take
an arbitrary caller-provided “already validated” report or trust a persisted
cursor. Both require native inspection-only access and no writable FD.

`Reader.reduce_while` takes a private view produced in this same session. It
must stop on the first visitor error, close the read FD, and return no final
accumulator or accepted remainder. Returning `{:halt, acc}` for successful early
completion is deliberately not supported: normal recovery must reach all
required history. Unknown callback return values are callback-contract errors.
Existing `Reader.reduce/3` and `Segment.reduce` retain their arbitrary-accumulator
behavior for physical tests; implement the new path by sharing the parser's
framing loop, not by duplicating the wire decoder or using exceptions as normal
control flow.

File scopes use exception-safe cleanup for return, halt, throw, exception, exit
and cancellation. A callback failure is never disk corruption. If cleanup also
fails, retain the original error and add bounded cleanup context; never replace
the primary semantic/corruption diagnosis with a generic close error. Helper
uncertainty additionally poisons the owner regardless of the primary diagnosis.

`position` has precisely:

```elixir
%{store_id: binary_16, segment_id: positive_uint64,
  record_offset: nonnegative_integer, next_offset: nonnegative_integer,
  sequence: positive_uint64}
```

Offsets are absolute within the segment, half-open boundaries. For a 28-byte
first record they are 44 and 72. Footer and header bytes are never delivered as
events. Sealed EOF is not the last record's next offset because the footer lies
after that boundary. Across files the next record starts at offset 44, with the
same global sequence progression, not by adding 64 to a replay cursor.

Maintain separate physical cursor, last semantically accepted sequence, and
last successfully reduced sequence. A complete physical frame advances only the
first. The others advance only after their own gates. All are volatile during
the attempt, and errors publish no successful recovered state. Diagnostic
progress is not an applied or durable checkpoint.

### 8.2 Semantic provider contract — no encoding selected

The internal `Tay.Storage.Recovery.EventDecoder` behaviour defines:

```elixir
known_type?(type_integer) :: boolean()
supported_schema?(type_integer, schema_integer) :: boolean()
decode_payload(type_integer, schema_integer, payload_binary, limits) ::
  {:ok, inert_event, consumed_bytes} | {:error, bounded_reason}
```

The provider module is explicitly configured trusted code, never named by disk
bytes. Its capability definition is fixed for an attempt; no hot code reload or
mutable registry update during recovery. This behaviour describes a boundary,
not an assignment of production type/schema numbers or a durable payload format.
Test implementations use artificial meanings only under `test/support/`.

After complete physical preflight, the per-record order is:

1. Recheck framing/integrity and global sequence against the pinned view.
2. `known_type?`; false stops with `:unknown_event_type`.
3. `supported_schema?` for that exact type; false stops with
   `:unsupported_payload_schema`.
4. Decode/validate the entire payload within resource budgets. Require
   `consumed_bytes == byte_size(payload)`; reject zero/partial/over consumption
   for a nonempty payload. Payload trailing bytes are not record remainder.
5. `reducer.(event, position, acc)` returns `{:ok, next_acc}` or `{:error, reason}`.
   A domain rejection becomes `:consumer_rejected`; Phase 4 will define valid
   job transitions through a shared implementation used for live and replay.

No implicit all-supported provider, lower-schema fallback, `skip`, no-op event,
atom creation from bytes, worker loading/execution, or unsafe deserialization.
Missing provider is an argument/capability error **before acquiring storage**,
including for an empty store. Physical inspection remains available separately.
ETF remains unapproved. A provider exception/throw/exit is an infrastructure
callback failure, not evidence that the bytes are a repairable tail.

Do not implement a production decoder merely by returning raw bytes as an event.
Actual production replay remains blocked until a separately approved Event RFC
defines supported meanings, payload validation, worker/job identities, schema
evolution, resource enforcement, and fixed semantic fixtures. Phase 3 tests can
prove the gate contract without claiming production job recovery.

### 8.3 Integrated ownership and activation

```elixir
Writer.start_recovered_link(storage_options, replay_spec)
# {:ok, pid} only after successful replay; pid is awaiting activation, not writable

Writer.activate_recovered(pid, session_ref)
# {:ok, activation_summary, candidate_acc} | {:error, recovery_error}

Writer.append(pid, admission_ref, type, schema, payload)
Writer.seal(pid, admission_ref)
Writer.rotate(pid, admission_ref)
# recovered-session mutations; otherwise the existing Phase 2 result contracts

Writer.status(pid)
# distinguishes awaiting_activation / ready / terminal / poisoned
```

`replay_spec` contains exactly `codec`, `initial_acc`, `reducer`, and `options`.
Use the same Writer GenServer and temporary restart policy, a separate startup
branch, the new native existing-only acquisition, and synchronous Recovery calls
in the owner. Do not run the current mutating `prepare/1` first. Initializing
recovery must use an explicit startup timeout adequate for the replay deadline.

The actor holds the candidate privately after replay. Its status exposes a
bounded summary and an opaque BEAM `session_ref`, not event payloads. Only the
same live actor/Port generation accepts that reference, once; retries with it
return an explicit already-activated/stale error, never repeat publication.
`append`, `seal`, `rotate` and raw reduction are denied until activation. The
recovered branch also requires a distinct admission reference on mutation admission,
so a request queued during initialization without a valid reference cannot
become executable merely because it is processed later. That admission reference
is generated only on successful activation and included in `activation_summary`;
the pre-activation `session_ref` is not accepted in its place. No engine process is
given mutation authority before activation succeeds. The unchanged physical
Writer entry point is not an alternative normal-recovery route.

Activation revalidates the entire physical view under the same lock, then
performs only the already approved Phase 2 initialization/publication barriers
for an initialized store (§11). It returns the candidate only after success;
on failure the candidate is discarded. `candidate_acc` is state input, not a
claim that ETS was published or jobs can run. Concrete ETS ownership transfer,
index publication and dispatch remain Phase 4 and later work.

The approved Phase 3 API recovers **existing initialized stores only**.
Missing STORE, bare-header genesis and uninitialized roots get explicit
initialization-required errors, without creating anything. Phase 2's approved
bootstrap remains a separate operation, legal only under its existing rules;
normal recovery must never route a missing/corrupt marker into that operation.
No bootstrap behavior is removed from the Phase 2 physical tooling.

## 9. Results, errors and deterministic precedence

Inspection contains store identity, canonical per-segment summaries, highest
active/sealed state, total counts, physical last sequence, next candidate or
`:exhausted`, and bounded staging/ignored-entry counts. A replay result adds
provider identity and last accepted/reduced coordinate, with `scope: :candidate`.
Neither result contains raw native handles or a persisted repair/checkpoint token.

A `Recovery.Error` has a fixed bounded shape:

```elixir
%{stage: stage, kind: kind, reason: bounded_reason,
  store_id: binary_16_or_nil, segment_id: id_or_nil, offset: offset_or_nil,
  sequence: validated_sequence_or_nil, physical_reason: original_reason_or_nil,
  action: :preserve_and_stop, mutation: :none | :activation_uncertain,
  cleanup_error: bounded_reason_or_nil}
```

Kinds distinguish argument, ownership/busy, initialization-required, discovery,
unsupported physical format/flags, physical corruption, continuity, incomplete
tail, unsupported semantics, invalid payload, resource limit, I/O, callback,
changed view and uncertain activation. Preserve Phase 1 nested reasons verbatim
where bounded. Sequence/type/schema from an incomplete CRC-validated header are
labelled diagnostic, not accepted. Never derive trusted fields from an unchecked
header. Do not include payloads, decoded job args, reducer state, exception
messages that may contain secrets, or unbounded filename/ID lists.

Global precedence is explicit:

1. Arguments, trusted provider availability, configuration and budgets.
2. Existing-root/lock acquisition and platform/ownership checks.
3. Complete listings and structural name classification; canonical ordering.
4. STORE validation, segment scans in numeric order using unchanged Phase 1/2
   byte-check precedence, then complete cross-segment topology validation.
5. Semantic replay in sequence order, with the per-record gates of §8.2.
6. Final physical view checks, activation barriers, then result publication.

Do not validate semantics in pass 1. Thus later physical corruption can take
precedence over an earlier unknown Event; nothing is replayed or mutated in
that case. With a physically valid store, unknown B in A/B/C stops semantic
replay at B: C is not decoded semantically or reduced. Physical preflight may
have inspected C at its exact boundary; that is not semantic replay beyond B.

Sort raw directory names for stable diagnostic selection after bounded complete
listing; numeric canonical order controls scans. If listing itself fails or
exceeds a budget, report that operational failure without claiming a complete
inventory. Do not promise deterministic errno ordering under external I/O races.
For fixed bytes, capabilities and resources with successful I/O, result/first
semantic failure and reduced state must be deterministic.

STORE unsupported-version/flag errors must not be mislabeled as repairable
corruption because of Reader's current outer wrapper. Normalize from the nested
reason without changing STORE decoding or byte-check precedence. Every failure
before activation keeps namespace and file contents untouched; activation
failures follow the more precise §12 crash contract.

## 10. Native existing-only inspection and capability transition

Additive private Port operations retain the existing v1 packet framing,
reply-ID matching and error/uncertainty rules unchanged:

| Operation | Request body after existing version/opcode/ID prefix | Result / effect |
| --- | --- | --- |
| 18 `ACQUIRE_EXISTING` | `strict:u8`, `operator_validated:u8`, `max_directory_entries:u32`, `absolute_path:str` | Existing acquisition facts; session becomes inspection-only; never creates directories or lock |
| 19 `ENABLE_MUTATIONS` | empty | Empty success only after deferred capability/barrier checks; same lock, no owner transfer |

Opcode assignments are approved internal ABI choices, not on-disk fields.
Old helpers reject opcode 18; report incompatible helper and stop. Never fall
back to opcode 1 acquisition when inspection-only access is requested. Existing
opcode 1 and Phase 2 physical sessions keep their approved behavior. The matched
application/helper build is required; do not probe a storage mutation to guess
whether a binary supports the new protocol.

`ACQUIRE_EXISTING`:

1. Validate the entire packet/options before any action. Require a non-root,
   explicitly configured absolute path, existing no-follow ancestor directories,
   supported filesystem/selected mode, and nonzero resource cap.
2. Open the existing `.tay-owner.lock` without `O_CREAT` or truncation, require
   regular/single-link matching inode, acquire `LOCK_EX|LOCK_NB`. Missing lock
   fails `:ownership_unavailable`; busy fails without scanning history.
3. Pin existing directories and inspect only after ownership. Do not create
   missing `segments/`; its absence remains an initialization/history error
   determined by the locked Reader. No marker/header/stage is created.
4. Permit only list, read-only open/pread/close, check/info and shutdown until
   explicit promotion. No write FD, file/directory sync, mkdir, publication,
   canonical open-for-write, or second acquisition is permitted in this state.

Use the same no-follow/inode/link protections, filesystem restrictions and
owner checks as Phase 2. A writable-mode open of the *existing lock* need not
write it; no segment is opened writable during inspection. Reads may update OS
access-time metadata and fill caches; “untouched” here means file bytes, lengths,
identities and directory entries are unchanged by Tay, not forensic zero-I/O.
There is no promise to prevent unrelated OS writeback of already dirty pages.

`ENABLE_MUTATIONS` is issued only by the Writer after semantic replay/reduction
and final view validation. It requires no open read/write descriptor and retains
the same lock FD. Recheck paths and full filesystem capabilities, then discharge
Phase 2's deferred ancestor-entry, lock-file and root/segments publication
barriers. Do not silently weaken the ancestor resync fix because the directory
already exists. Any failure/timeout poisons the session; no promotion retry on
the same uncertain connection. The helper enforces capability state, while
the trusted Writer is responsible for the semantic authorization condition.

No truncate/delete/repair opcode is added. Deferred promotion must not perform
bootstrap or create a successor by itself; that remains the Writer's existing
explicit Phase 2 protocol after it receives promotion success.

## 11. Recovery/activation algorithm and state machine

Use volatile state names distinct from physical segment states:

| State | Allowed work | Successful next state | Failure action |
| --- | --- | --- | --- |
| Q0 validating | Validate arguments/provider/budgets | Q1 | No filesystem action |
| Q1 acquiring | Existing-only ownership and read-only capability | Q2 | Close/release; no retry/bypass |
| Q2 preflighting | Full physical inventory/marker/segment/topology validation | Q3 | Preserve bytes; no consumer call |
| Q3 replaying | Ordered semantic gate and private reduction | Q4 | Discard candidate; preserve storage |
| Q4 awaiting_activation | Retain candidate/view/lock; expose bounded status | Q5 on exact live session reference | Expiry/stop releases lock; no mutation |
| Q5 revalidating | Repeat full physical preflight and compare frozen view | Q6 | Discard candidate; preserve storage |
| Q6 activating | Enable native mutations; Phase 2 barriers and approved highest handling | Q7 or Q8 | Poison; report activation uncertainty |
| Q7 ready | Admit referenced, upstream-validated Phase 2 append/seal/rotate calls | Existing Writer states | Existing poison rules |
| Q8 terminal | Read-only valid result at exhausted coordinate space | Closed | Reject appends; never reset counters |
| QX failed/poisoned | Bounded diagnosis and cleanup only | Closed | Never self-repair or retry |

Q2 begins at canonical ID 1, FIRST 1. No snapshot, starting-sequence option,
manifest hint or arbitrary seek is accepted. Read all canonical files and
STORE; require every earlier segment sealed and the highest either valid active
or valid sealed. All v1 identity, CRC, reserved-value, size and sequence checks
remain in their approved order. A nonempty incomplete canonical suffix ends Q2.
No candidate prefix may be published as a successful replay.

The frozen view contains the store marker's identity/bytes, ordered canonical
names, device/inode/size/link metadata, header and footer facts, and recomputed
per-segment CRC state (including the active area), plus bounded inspected
namespace facts. It is tied to the current Port generation. Staging and ignored
files remain non-events and are never used as alternative history. Directory
listing changes between passes fail as `:changed_view`, not as an invitation to
merge new files into a replay already in progress.

Q3 rechecks file identity and frame/sequence integrity while visiting the view.
The global expected sequence is retained across files, never reset to whichever
FIRST happens to be observed. Read errors/short reads against the captured
extent are I/O/changed-view failures, not a newly inferred torn tail. Semantic
and consumer failure halt immediately. Compare end summaries against the view,
including the active CRC, before Q4. Consumer effects must be private/pure;
withholding a return value cannot roll back an external side effect.

Q5 repeats physical validation, compares every canonical summary/identity and
inventory against the Q2/Q3 view, then checks the lock and closes all read FDs.
This is intentionally an additional O(history) startup pass, not a per-append
scan. It detects ordinary changes during the caller's activation gap; CRC
collisions/coordinated replacement remain the approved detection limit. No hot
Event-provider code/config changes are allowed between Q3 and activation.

Q6 handles initialized highest segments only:

- **Valid active:** sync the marker/directories and active file as required by
  Phase 2; open only its canonical FD with the validated identity and EOF.
  Recompute sequence/CRC from validated history, not an old process cache.
- **Valid highest sealed, headroom available:** re-sync the old sealed file
  through a read-only FD, then perform exactly Phase 2 R3–R7 with an empty
  header successor. No old sealed inode is reopened writable. Revalidate the
  expected post-creation topology; the only new canonical contains no records.
- **Exhausted sequence or sealed segment-ID space:** return Q8 without creating
  a successor or opening a canonical writable. Discharge the same existing-file
  and directory barriers through read-only descriptors, including the highest
  file, before completing activation. Return no mutation admission reference.
  Represent next sequence as `:exhausted` at this API, never serialize zero or
  uint64 overflow. If only segment-ID space is exhausted, retain the arithmetic
  next sequence separately as diagnostic data; it is not an append permission.
- **Active at maximum segment ID but sequence headroom remains:** Phase 2 may
  append while the existing file has capacity; the next required rotation fails
  explicitly. Do not prematurely call the entire store exhausted solely because
  its active ID is maximal.

Q7 readiness means **storage activation only**. No scheduler/job execution is
implemented, and no job is acknowledged merely by receiving this result.
Phase 4 must stage/publish its indexes and later startup must pass its own engine
readiness gate before dispatch. A recovered actor/helper failure invalidates
that generation; later integration must revoke all consumers of it together.

## 12. Crash/restart semantics and recovery matrix

No progress checkpoint is persisted in Phase 3. A new attempt starts at genesis
under a newly acquired lock. A candidate/result from a dead owner cannot be
resumed or used to activate another writer. No automatic uncertain-mutation
retry is introduced; temporary supervision is retained.

| Crash/failure window | Possible persistent effect | Next attempt |
| --- | --- | --- |
| Q0 or busy/missing ownership | None by this path | Correct options/ownership; do not initialize implicitly |
| During Q2 physical pass | None by this path | Full preflight again; same bad bytes still fail |
| During Q3 semantic decoding/reduction | None; candidate is lost | Full replay; no external consumer effects are permitted |
| Unknown type/schema or invalid payload in Q3 | None; no later semantic event delivered | Use an explicitly supporting/valid deployment or investigate; no rewrite/skip |
| Q4, before activation request | None; lock eventually releases | Discard candidate; replay again |
| Q5 changed view or read/close failure | None by recovery; external change may be observed | Preserve evidence; no stale-view activation |
| During native promotion/barriers | Some existing dirty bytes/entries may have been synced; no new Record | Poison on uncertainty; revalidate on a new attempt |
| During highest-sealed successor creation | Exactly Phase 2 R3–R7 observations: absent/partial/full stage or complete empty canonical | Retain stage; run full physical AND semantic replay before any next activation |
| After activation but before caller receives its result | An empty successor may exist and activation may have succeeded; no append from that unpublished admission reference | Do not infer failure; stop old owner or inspect status, then explicit fresh recovery if reopening |
| Later complete append, failed sync/lost reply | Full frame may occupy the next sequence | Preserve it; if physically and semantically valid, include it in replay; no prior ACK claim |
| Later incomplete append/footer/canonical suffix | Exact incomplete suffix may remain | Preserve all bytes and stop; no partial state, occupied/ambiguous counter reuse or writable restart under the approved Phase 3 policy |

Every complete, physically valid, contiguous and semantically understood event
must participate in replay regardless of whether a caller saw success.
This follows Phase 2's sequence-occupancy rule. Excluding an unacknowledged but
complete completion/cancellation could produce the wrong reconstructed state;
the file contains no safe “ACK-only replay” selector. Including such an event
does not prove the caller received success or promise exactly-once insertion.
Future Event/insertion semantics must account for unknown-commit reconciliation.

Highest-sealed successor creation is deferred until *all* events and private
consumer transitions succeed, not merely until the highest file is readable.
An unsupported event in any earlier file therefore cannot cause an empty next
canonical or staging file to appear through failed downgrade recovery.

## 13. Invariants affected

| Invariant | Phase 3 obligation |
| --- | --- |
| A — acknowledged durability | Never discard observable history or reinterpret write-mode receipts as durable acknowledgements; keep Phase 2 barriers before new strict receipts |
| B — disposable ETS | Produce replay input only; no hidden state source or durable cursor derived from runtime ETS |
| C — torn append safety | Retain original codec classification; no padding, scanning, suffix rewriting or incomplete-as-authorization shortcut |
| D — durable existence | Withhold engine/dispatch readiness; physical success alone cannot create an executable job |
| E — worker isolation | Do not call workers in recovery; codec/reducer infrastructure failures cannot mutate storage |
| F — deterministic replay | Stable provider, explicit order, deterministic pure reduction and all-or-error publication |
| G — indexed runtime | Startup scans are allowed; this phase adds no historical scans for job dispatch |
| H — at-least-once | Keep complete uncertain events and expose ambiguity; no exactly-once claim or replay-time retry transition invented |
| I — explicit corruption | Stop on all required physical/semantic failures; preserve underlying categories and evidence |
| J — persisted/runtime separation | No ETF/job-struct persistence, atom/module lookup from disk, or event allocation by physical fixture numbers |

Additional operational invariants: one helper/lock throughout the session; no
writable segment FD before activation; no partially recovered public state;
no skipping; no stale report as authority; no silent mode downgrade; no epoch
survives a failed owner; and no repair operation in the approved native ABI.

## 14. Filesystem and durability guarantees/non-guarantees

Keep the approved Phase 2 platform contract: strict `:sync` only on explicitly
operator-validated local Linux filesystems with file/directory fsync, flock,
exclusive no-follow fd-relative operations and atomic no-replace publication.
The current adapter allowlist is ext-family/XFS/Btrfs; its allowlist is not
proof that every deployment is certified. Phase 2 verified Linux paths on Btrfs.
Development `:write` on supported local macOS is not strict power-loss durability.
No new platform, network filesystem, temporary production default, F_FULLFSYNC
protocol or durability mode is introduced here.

Inspection/replay success certifies the currently observed valid bytes and
selected semantic interpretation, **not** previous acknowledgements or survival
of every record ever written. Activation discharges applicable Phase 2 barriers
before new writes; changing from write to sync today cannot retroactively prove
that older write-mode acknowledgements survived a past crash.

File sync and pathname durability remain distinct dependencies; syncing a file
alone does not discharge publication of its directory entry.
[Linux fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html)
Delaying those barriers until after the semantic gate changes their timing
relative to inspection, not their required ordering before any new ACK.

Advisory locking excludes cooperating concurrency, not arbitrary external writes.
Offline copy/restore, migration, administrative mutation and hot code deployment
must not race a recovery attempt. Path/inode/size/CRC checks detect many observed
violations, not all same-size forged substitutions or storage-device failures.
Clean loss of a last active suffix, loss of an entire highest successor, or
replacement by an older consistent complete store can remain undetectable.
Checksums/STORE are not authentication, redundancy, backup or anti-rollback.

## 15. Limits, concurrency and cancellation

Format hard limits remain immutable:

| Item | Limit / rule |
| --- | --- |
| Record payload | 16,777,216 bytes; total frame at most 16,777,244 |
| Segment | 1,073,741,824 bytes sealed; at most 1,073,741,760 active |
| Fixed objects | STORE 28, header 44, footer 64 bytes |
| IDs / sequences | Nonzero uint64; no wrap; complete final maximum allowed |
| Sealed record count | At most 38,347,918; existing physical bounds still apply |
| Native packet | Existing 16,785,436-byte maximum; never split an oversized listing into a misleading partial success |

Approved **operational**, non-persisted options (G5); these defaults and budgets
must never change physical validity:

| Option | Approved operational default / validation | Failure behavior |
| --- | --- | --- |
| `max_decode_payload_bytes` | 16,777,216; integer 0..16,777,216 | Pass through to Record on every scan/pass; resource failure, never incomplete |
| `max_directory_entries` | 100,000 per directory; positive uint32 | Native enumeration stops with resource error, no partial listing; existing packet cap can be reached earlier |
| `max_total_segment_bytes` | `:infinity` or positive integer | Sum canonical extents with checked arithmetic before scanning; never change per-file format validity |
| `max_replay_records` | `:infinity` or nonnegative integer | Count complete records during preflight; zero permits only a genuinely empty store; no partial successful replay |
| `deadline_ms` | 900,000; positive integer | Overall acquisition/preflight/replay deadline; explicit timeout, no readiness |
| `activation_window_ms` | 30,000; positive integer | Time allowed to request activation after Q4; expiry drops candidate and closes session |
| `activation_deadline_ms` | 900,000; positive integer | Bounds admitted Q5/Q6 work cooperatively and per I/O; expiry may be uncertain once activation began |
| `io_timeout_ms` | 10,000; positive integer | Per helper reply, capped by remaining phase deadline; unknown outcome poisons |
| `event_limits` | depth 64; output nodes 100,000; aggregate binary bytes 16,777,216 | Provider-enforced decoding budgets; no payload-format allocation or insertion rule follows |

Unknown/duplicate options fail before acquisition; no silent ignored recovery
option. The directory entry cap is a resource policy, not a new maximum segment
ID/count in the format. Resource-limit failures must leave storage untouched
and be retryable with a larger budget. Raising a budget permits a fresh attempt
on unchanged bytes; it cannot bypass the current native packet cap. A future
paged listing protocol needs its own completeness/stability design, not implicit
pagination.

Complete deterministic resource-admission checks before enabling mutations,
including capacity for a required empty successor, transient publication entries
and post-creation verification. A configured-budget refusal must not first occur
after creating a stage/successor. Once Q6 mutation/barrier work has begun, an I/O
timeout or activation-deadline expiry follows Phase 2 activation uncertainty
(§12); it is not a retryable, storage-untouched resource-limit result. No rollback,
cleanup deletion or same-session uncertain retry is authorized by G5.

Each pass uses at most one read FD, one bounded Record and small envelope buffers,
plus O(bounded directory entries/segment summaries) metadata. Native/Port/BEAM
copies mean several frame-sized buffers can coexist; do not claim the whole
process uses only 16 MiB. The three principal passes are O(total stored bytes)
each; reusing Phase 2's successor publication may add another physical
reinspection, which remains subject to the activation deadline. There is
no all-record list or million-record mailbox. The chosen reducer's candidate
memory is additional: trusted consumers must enforce their own state-size limit.
The Phase 4 ETS/state-size policy is not decided by these scanner limits.

Event limits are an approved interface budget, not a generic sandbox or exact
BEAM RSS meter. A real codec must enforce depth/node/byte limits *while decoding*,
before expansion/allocation, and its payload RFC must specify how its inert
representation is counted. A post-decode size check alone is insufficient. No
compression is introduced; a future approved compressed schema must account for
expanded size independently of the 16 MiB framed payload limit.

Recovery is synchronous in one owner: no parallel semantic replay, async
prefetch, second Reader actor owning the same handle, live appends during scans,
or callback reentry into the Writer. The trusted provider/reducer must not block
on the owner, read wall clock/randomness for state reconstruction, execute user
workers, or perform arbitrary external I/O. Replay time may affect diagnostics
and deadlines, never the meaning/order of historical events.

Check monotonic deadlines between directory entries, bounded reads and events.
They cannot preempt a hanging arbitrary callback or a kernel-stalled syscall by
themselves. The supervising caller must monitor and terminate a stalled owner
when necessary; helper EOF/lock cleanup then follows the existing native model.
Do not promise responsive `status` calls during synchronous scans. A caller-side
GenServer timeout is **not cancellation** and does not prove the server stopped
or an activation failed. Do not retry activation on that basis.
[Elixir GenServer call/timeout contract](https://elixir.hexdocs.pm/GenServer.html#call/3)
Startup/activation caller loss invalidates any unpublished reference; explicit
owner shutdown or a new locked attempt is required, not use of a leaked candidate.
Timer messages must be generation/state checked so a Q4 expiry cannot abort an
already admitted Q5 merely because its old timer arrived late.

## 16. Recovery behavior and adversarial matrix

Every row assumes required ownership; no row grants truncation. “Success” below
means candidate replay only unless activation is explicitly mentioned.

| Observed condition | Required result / downstream behavior |
| --- | --- |
| Initialized empty active, ID1/FIRST1 | Zero events, next candidate 1; complete validated empty replay, no synthetic event |
| All complete contiguous records | Replay every understood event in order, including complete records with unknown prior ACK status |
| Highest sealed without successor | Replay its events; retain sealed state until separately requested successful activation creates only the Phase 2 empty successor |
| Highest empty successor after rotation | No consumed sequence in that file; use its FIRST only after preceding LAST+1 validation |
| Partial Record header/payload/checksum at highest EOF | Incomplete-tail error with exact boundary/metadata; no candidate success, no overwrite/reuse/truncate |
| `T`, `TA`, `TAY` after complete records | Ambiguous short tail, not a proved Record/footer; preserve and stop |
| Partial footer, including apparently matching expected footer bytes | Incomplete-footer error; never remove, complete, or relabel it active |
| Zero/partial canonical header | Invalid/incomplete canonical history; never delete as an orphan or silently bootstrap |
| Bad header/record/footer/segment checksum | Preserve exact corruption reason; no scan, salvage, padding or truncation |
| `[A][damaged B][valid C]` | Stop physical preflight at B; retain all B/C bytes; no semantic candidate |
| B length changed with original header CRC | Header checksum before length; no allocation/truncation based on corrupt N |
| B length and CRC recomputed so C lies in apparent incomplete payload | Classification can be incomplete, but action remains preserve-and-stop; no deletion of hidden C |
| Physically valid A/B/C with B unknown type/schema | Fail semantic replay at B; no B/C reduction or activation; namespace/bytes unchanged |
| Unknown-semantic B with incomplete body or bad CRC | Physical failure takes precedence; do not run Event decoder or infer repair permission |
| Known pair with invalid/trailing payload bytes | Stop before consumer; unknown-schema fallback and partial decoder consumption forbidden |
| Valid event rejected by pure consumer | Candidate discarded; no storage mutation/readiness; domain transition rules remain Phase 4 |
| Sequence duplicate/decrease/gap, wrong first anchor | Continuity error before Event; no dedup/rebase/synthetic event |
| Earlier active, incomplete or corrupted sealed history | Fail entire store even if highest is valid; no downgrade to an active prefix |
| Full footer plus random tail or duplicate footer | Exact placement/trailing error; no acceptance of the good prefix |
| Missing ID1/intermediate ID/foreign STORE identity | Discovery/topology/identity error; never adopt remaining FIRST as genesis |
| Missing/corrupt STORE | Initialization/history error; no identity inferred from existing nonempty segments |
| Bare ID1 complete header and no STORE | Explicit initialization-required result; Phase 2 genesis completion is a separate approved operation, not recovery's fallback |
| Existing empty root or recognized stages only, no STORE | No automatic bootstrap; explicit separate initialization required |
| Valid-sized recognized staging file | Inspect name/type/link/size; retain and do not replay; never promote it as evidence of a record |
| Oversized/malformed stage, symlink/hardlink/special file | Discovery failure; no deleting evidence to make startup pass |
| Resource budget below valid stored requirement | Operational failure; retry with adequate budget on the same untouched store |
| Missing lock or uncooperative pathname replacement | Ownership/changed-view error; do not create a new lock to get around it |
| Later files differ between passes | Changed-view failure; candidate invalid; no merge or stale activation |
| Complete maximum sequence | Valid terminal replay; no wrap or new successor |
| Clean suffix/whole newest segment disappears without surviving evidence | May look valid under existing format; document detection limit, never claim recovered missing bytes |
| Snapshot/manifest-looking unrelated file | No authority to skip/rebase history; current Phase 2 entry classification still applies; unsupported directory layout fails |

Unsupported framing/flags/STORE/segment versions stop before assuming a newer
layout; no semantic registry is moved back into Record or Segment. An incomplete
footer's current parser category may not expose every available prefix byte's
meaning; because **all** such tails stop, Recovery must not use that category
to infer v1 compatibility or repair permission.

## 17. Required implementation test strategy

These are **future acceptance tests**, not tests claimed to have run in this
design-only turn. Run on disposable explicitly configured storage only. Record
faults and stage transitions deterministically; use monitors/barriers, not
arbitrary sleeps. Retain all existing Phase 1/2 assertions and golden bytes.

### 17.1 Pure and compatibility tests

1. Decode all 18 Record and 22 segment artifacts unchanged. S13's wrong anchor
   remains a failure; S15 remains valid physical history. Semantic support in a
   test provider must not change any physical fixture result or allocate real
   job-event meanings to fixture numbers.
2. Independent replay oracle over generated contiguous records/multiple segment
   boundaries: same input/provider/initial state yields the same final candidate
   and positions. Use an independent pure test reducer, not the implementation
   under test to generate its expected result.
3. Empty history, maximum sequence/ID arithmetic, exact 16 MiB frames, maximum
   active/sealed geometry, and historical files above a newly lowered insertion
   target. Small arithmetic models for exhaustion must not pretend a FIRST-max
   segment is valid fresh genesis.
4. Every retained prefix of small Record frames and all partial footer lengths;
   exact EOF distinction, partial magic mismatch and unknown framing precedence.
5. Mutate every framing field and both CRC levels; include recomputed-CRC fields
   reaching domain checks, unknown assignable types/schemas, and embedded magic.
   Preserve the distinction between single-bit detection and arbitrary collisions.
6. Test unsupported STORE normalization and combined faults for global/per-layer
   precedence. Test all independent resource options, malformed options and no
   successful partial inventory. Budget failure must never change stored bytes.

### 17.2 Mandatory semantic gate and consumption tests

1. A/B/C with B unknown type; repeat unknown schema, invalid payload and trailing
   payload bytes. Instrument provider and consumer calls separately from physical
   scans. Physical preflight may visit C; semantic decoding/reduction must not.
2. Unknown A plus a later physically damaged tail: preflight fails with physical
   error and no semantic callbacks or mutation. Incomplete unknown B remains
   incomplete, not safely discardable. No early semantic acceptance from header
   metadata and no post-error checkpoint advancement.
3. Visitor `{:error, reason}` halts immediately in the **new** traversal API;
   the old physical accumulator API retains its existing semantics. Bad callback
   returns, raises, throws/exits and cleanup errors yield bounded classified
   failures and close/release resources without emitting a final accumulator.
4. Provider missing, provider capability changes, unsupported-schema fallback
   attempt, partial decode consumption, depth/node/expansion limit and payload
   that resembles ETF. No atom creation, worker resolution or callback execution.
5. Use a fresh independent BEAM with absent/renamed worker modules and a bounded
   inert test decoder. The physical bytes stay readable; test semantics depend
   only on the explicit provider, not already interned worker atoms/modules.
6. Consumer transition rejection on a late event discards earlier private
   candidates. No dispatcher/public ETS/checkpoint API is invoked at any point.
7. No wall-clock/random input to the reference reducer. Repeat successful full
   replay after process restart and compare candidate state and logical positions,
   excluding intentionally different volatile session references/timing diagnostics.
8. Give identical complete contiguous test histories different external ACK
   observations (known success, lost reply, unknown). All understood events must
   replay with identical state and occupied/next sequence results; no production
   ACK selector or exactly-once inference may appear.

### 17.3 Ownership, no-mutation and activation tests

Before each failing attempt snapshot **all** directory entries, regular-file
bytes/lengths and identities, including STORE, canonical files, recognized
stages and the existing lock. Compare after failure, excluding access times and
test-owned diagnostics. Do not only check the last record count.

- Second independent BEAM gets busy before preflight. Missing root/lock creates
  nothing. Symlink/hard-link lock, changed directory inode, canonical substitution,
  missing/zero files, foreign store and malformed raw names fail closed.
- Existing-only helper rejects every mutating opcode including sync, stage
  creation and canonical writable open before promotion. Old helper rejection
  of opcode 18 never triggers fallback to the creating acquisition path.
- Unknown semantics in an otherwise valid highest-sealed store produces no
  successor/stage/marker write and no explicit file/directory sync. Repeat with
  earlier known events and a later unsupported event.
- Hold the same helper PID and lock inode across Q1–Q7. Another BEAM remains
  excluded throughout the activation gap. No fresh Port or release/reacquire.
- Queue a raw/old-reference mutation before readiness and verify denial. Stale
  generation, repeated activation, expired lease and references copied to a
  different store/owner never authorize mutation. The admission reference is
  unavailable before successful activation.
- Change a canonical's bytes without changing inode/size between Q3 and Q5;
  recomputed view must detect ordinary CRC-changing edits. Replace STORE or a
  whole canonical between passes; include a new unexpected directory entry.
- Clean active, empty active, highest sealed and exhaustion activate with the
  exact permitted descriptor states. In particular the sealed-high file is
  never reopened writable, and no new canonical can hold records before R6.
- Retain stages across repeated attempts; prohibit truncate/delete/rename-aside
  operations on every failure path. No manual cleanup step may make a negative
  recovery test appear to pass.
- Set budgets that admit the existing highest-sealed history but cannot cover
  required successor/publication verification. Refuse before promotion or stage
  creation, preserve the entire inventory and retry successfully with sufficient
  budgets. Separately test post-promotion timeouts as activation uncertainty,
  never as untouched retryable resource-limit failures.

### 17.4 Crash/fault matrix

Kill the owner/helper or inject short read, I/O error, unsupported operation,
timeout, dropped/mismatched reply and close failure at each relevant boundary:

| Boundary | Assertions |
| --- | --- |
| Existing acquisition before/after lock | No new names; no concurrent ownership; eventual release without deleting lock |
| STORE/list/header/record/footer read in Q2 | No candidate/activation; exact physical vs I/O result; no short-read-as-EOF repair |
| Before/after Event gate and reduction in Q3 | No later semantic calls; candidate discarded; unchanged storage |
| Last event / Q4 result / activation lease expiry | No premature mutation; expired/dead generation cannot activate |
| Q5 repeat validation / final close | No stale candidate; preserve primary error plus cleanup failure |
| Each deferred ancestor/lock/root/segments barrier | Any failure blocks readiness; unknown reply poisons; no retry |
| Existing active file sync/open | No ACK/readiness before successful barriers and exact identity match |
| Highest-sealed activation R3–R7, including both close boundaries | Same Phase 2 visible file sets; retained stages; no record added; full semantic replay again after restart |
| Activation result lost / later append result lost | No automatic repetition; complete stored records occupy their sequence on new replay |

Use an external **test harness** to remember which synthetic appends received
ACKs; its knowledge must not become a production recovery assumption or an
undocumented on-disk sidecar. Test every acknowledged fixture prefix unchanged,
not an inferred count from the damaged log. Under the approved policy, every
incomplete canonical result must assert refusal and exact evidence preservation.
Do not label those cases “automatic torn-tail repair passed.”

Exercise Linux strict sync on an explicitly validated local test volume and
macOS development write separately. Include true independent BEAM restarts and
helper kills; distinguish process-crash tests from actual power-cut/device
testing. Add ASan/UBSan coverage for new native packet and permission states.
Add an opt-in 1 GiB lazy streaming test and many-small-segment tests that measure
bounded reads/retention and deadline/resource failures, without requiring a giant
committed fixture. No test may claim all hardware power-loss behavior was proved.

### 17.5 Approved Phase 3 exit criteria

- Fully valid initialized v1 histories recover automatically through an explicit
  semantic test provider and the activation gates, replaying deterministically
  into private input and preserving full coordinates. This is not a production
  Event-format or job-recovery claim.
- Unknown semantics, consumer/physical failure, incomplete tail and resource
  exhaustion never publish partial success or mutate storage before activation.
- Single ownership survives the inspection/replay/activation boundaries without
  lock release, and all required Phase 2 barriers remain before readiness/ACKs.
- Every complete, physically valid, contiguous and semantically understood event
  is replayed even when its prior caller acknowledgement is unknown. Occupied
  sequence space is retained without a prior-success or exactly-once guarantee.
  Snapshots and arbitrary replay anchors are unsupported; all current byte
  fixtures remain identical.
- Future implementation runs formatter, warnings-as-errors compilation, the
  unchanged Phase 1/2 suites, new unit/property/integration/fault tests and startup
  checks, with exact commands/results reported.

The reconciled TAY_PLAN.md criterion “incomplete active tail recovers safely”
has exactly this approved meaning:

> an incomplete active tail is detected safely, preserves all evidence, never publishes partial recovered state, never reuses occupied/ambiguous sequence space, and refuses writable activation.

It does **not** require or authorize automatic destructive repair or automatic
writable restart. This applies to incomplete Records, footers and canonical
suffixes. Tests must prove precise diagnosis and preservation, not repair.
Automatic repair remains future separately reviewed work; no acknowledgement
metadata, repair journals, watermarks or format changes are introduced here.
G2 limits this phase to the EventDecoder behaviour and test-only providers; a
production Event RFC is a future dependency, not an unresolved Phase 3 gate.

## 18. Compatibility and exact future file scope

No change is demonstrated unavoidable to any of the existing byte contracts:
Record header/overhead, numeric domains, CRC parameters/coverage, 16 MiB bound,
STORE identity and 28-byte layout, 44/64-byte segment envelope, 20-digit names,
1 GiB bound, sequence anchors, reserved fields or active/sealed topology.
No new kind of disk file, recovery journal, persisted acknowledgement watermark, epoch,
format flag, record type or schema number is introduced by this approved design.

Physical compatibility is deliberately separate from semantic compatibility.
An older application can still physically decode newer assignable type/schema
values and must stop semantically when unsupported. A changed decoder/resource
budget is not corruption. No checkpoint skips an unknown event, and changing
worker code/runtime structs does not alter the physical framing results.

This approved design changes **internal control flow/APIs**, notably inspection-only
native acquisition, explicit halt-aware traversal and guarded Writer activation.
Existing physical `Writer.start_link`/append tooling remains for Phase 2 tests
and explicitly physical callers, never exposed as the future normal startup path.
The recovered branch rejects its legacy unreferenced mutation methods. This is
an admission restriction, not a weaker alternative durability mode. Bootstrap
and initialized-store recovery stay separate so absent storage cannot silently
become an empty recovered engine.

Approved implementation file scope, only after a separate implementation request:

| File | Exact work |
| --- | --- |
| `lib/tay/storage/recovery.ex` (new) | Coordinator, preflight/replay result handling, private view/session contracts and policy refusal |
| `lib/tay/storage/recovery/event_decoder.ex` (new) | Internal behaviour only; no production encoding, numbers or fallback implementation |
| `lib/tay/storage/recovery/error.ex` (new) | Small explicit bounded error type/normalization; no payload logging |
| `lib/tay/storage/reader.ex` | Expose resource-aware preflight and explicit halt-aware traversal; full coordinates and exception-safe file scopes |
| `lib/tay/storage/segment/parser.ex` | Share framing loop with halt-aware visitor, preserving physical API semantics and normative checks |
| `lib/tay/storage/segment.ex` | Add the minimal halt-aware delegation/types needed by Reader; no codec or layout change |
| `lib/tay/storage/native.ex` | Existing-only acquisition, promotion, session facts, per-attempt budgets and strict new-op reply checks |
| `c_src/tay_storage_helper.c` | New inspection capability state and bounded listing cap; no ftruncate/unlink/repair operation |
| `lib/tay/storage/writer.ex` | Separate recovered startup branch, retained owner/candidate, activation and admission-reference checks; reuse Phase 2 mutation protocol |
| `test/support/recovery_helpers.ex` (new) | Pure test Event providers/reducers, independent expected results, generation/fault helpers |
| `test/tay/storage/recovery_test.exs` (new) | Scope, results, coordinates and deterministic normal replay |
| `test/tay/storage/recovery_semantics_test.exs` (new) | Mandatory gates, exact consumption, callback and state-publication errors |
| `test/tay/storage/recovery_adversarial_test.exs` (new) | Corruption/incomplete/missing data, no mutation, compatibility and limits |
| `test/tay/storage/recovery_lifecycle_test.exs` (new) | Crash points, independent owner/BEAM, activation and strict syscall failures |
| `test/tay/storage/recovery_property_test.exs` (new) | Generated replay determinism, safe refusal, boundary and order properties |
| `test/tay/storage/recovery_large_test.exs` (new) | Opt-in large bounded replay and many-segment/resource tests |
| `test/tay/storage/native_protocol_test.exs` | New opcode/role denial, unsupported-helper and malformed packet cases |
| `c_src/README.md`, `docs/architecture.md`, `README.md` | Explain approved recovery/activation scope and operational constraints |
| `docs/phase-3-implementation-report.md` (future new) | Actual verification evidence; not created by this RFC |

No edit to Record/CRC32C, approved RFC byte tables, existing binary fixtures,
Tay.Job, Application/Supervisor startup wiring, queue code or dependency list is
required by the approved scope. Reuse fixtures by composition and create
adversarial bytes only in disposable test inputs; no new semantic golden format
is fabricated here. Existing test assertions are not weakened to accommodate
the new APIs.

## 19. Resolved approval gates and remaining dependencies

| Gate | Status | Binding decision |
| --- | --- | --- |
| G1 — torn-tail policy and Phase 3 exit | APPROVED | Fully valid histories recover automatically; incomplete Record/footer/canonical suffix is diagnosed precisely, all evidence preserved, no partial state published, occupied/ambiguous sequences never reused and writable activation refused. No truncation, padding, deletion, rename-aside or suffix repair. Automatic repair requires a future separately reviewed protocol; no acknowledgement metadata, repair journals, watermarks or format changes in Phase 3. |
| G2 — Event dependency | APPROVED | Only the explicit EventDecoder behaviour and test-only providers. No production type/schema allocation, ETF or other production serialization, or raw-bytes production fallback. Production Event semantics require a separate future RFC/dependency. |
| G3 — untouched inspection/replay | APPROVED | Existing-only acquisition; no creation of root, lock, STORE, segments directory, segment, stage or successor during inspection/replay. A missing existing lock is an operational ownership failure, never bootstrap permission. |
| G4 — continuous ownership and activation | APPROVED | Writer owner → same native helper/Port → same lock → physical preflight → semantic replay → private candidate → revalidation → mutation-capability activation. No release/reacquire or offline recovery ticket; recovered mutations require a distinct post-activation admission reference. |
| G5 — operational bounds and activation cost | APPROVED | §15 resource limits/defaults and pass costs are accepted as operational only, never persisted format limits or physical-validity rules. Resource-limit failures leave storage untouched and are retryable with a larger budget. |
| G6 — complete uncertain record semantics | APPROVED | Replay every complete, physically valid, contiguous and semantically understood event regardless of unknown prior caller acknowledgement. Preserve occupied sequences; do not imply observed caller success or exactly-once semantics. |

All six design gates are resolved. No unresolved design decision blocks the
approved Phase 3 interface/test-provider scope, and no Record/Segment/STORE byte
change is required. Source implementation still requires a separate user request.

Production Event semantics/serialization remain a future RFC dependency before
real job-event recovery can be claimed; they do not block implementing the
approved behaviour and test-only providers. Automatic torn-tail repair is
explicitly outside this phase, not an unfinished Phase 3 exit criterion. Neither
dependency permits an implementer to invent a fallback, new metadata or repair.

## 20. Design review evidence and stop point

The initial design-authoring turn read the documents listed in §2, inspected all
storage implementation modules and the native helper, examined relevant fixture,
lifecycle and ownership tests and the startup/configuration code, and confirmed
the initial worktree was clean at the commit recorded above. It created **only
this RFC**. No storage was opened for writing, no fixtures regenerated, and no
source/test/config file was modified.

Read-only probe executed during initial design authoring (exit 0; not rerun for
the approval reconciliation):

```sh
elixir -pa _build/dev/lib/tay/ebin -e 'bytes = File.read!("test/fixtures/storage/segment/v1/s03.tay"); read = fn offset, length -> {:ok, binary_part(bytes, offset, length)} end; IO.inspect(Tay.Storage.Segment.reduce(read, byte_size(bytes), [], fn record, _, _ -> send(self(), {:visited, record.sequence}); {:error, :semantic_stop} end), limit: 4); for _ <- 1..3 do receive do message -> IO.inspect(message) end end'
```

It returned a physical `{:ok, segment, accumulator}` and printed visits 1, 2, 3.
This supports the halt-boundary finding in §4; it is not a Phase 3 test suite.
Platform/OTP documentation was checked for lock lifetime, distinct file/directory
sync, Port ownership and call-timeout behavior, with sources linked at the
corresponding claims. These references do not expand the already approved
platform guarantee.

Initial design document checks passed: 10 local links exist, the 20 top-level
numbered sections are contiguous, code fences are balanced, and there is no
trailing whitespace.
`git diff --check` returned exit 0. The explicit untracked-file check
`git diff --no-index --check /dev/null docs/phase-3-recovery-rfc.md` emitted no
whitespace diagnostics and returned 1 because the file differs from `/dev/null`.
The initial design-authoring inventory contained only this new RFC. No Mix
tests/compilation were claimed for that design-only change; Phase 1/2 reported
results remain historical.
All §17 tests are future requirements, not passing placeholders.

The subsequent approval reconciliation updates only this existing RFC and
TAY_PLAN.md (§12 and Phase 3). It records G1–G6 as resolved, makes the approved
contracts/exit criteria normative and preserves the adversarial repair analysis
as future design input. No source, tests, configuration, Phase 1/2 byte-contract
document or fixture is changed. This is not Phase 3 implementation evidence.

Reconciliation verification: a read-only Elixir document check passed (exit 0)
for all 12 local-link occurrences across the two documents, balanced fences,
absence of trailing whitespace, contiguous RFC sections 1–20, all six APPROVED
gate rows and the exact approved tail definition in both files. No stale Phase 3
proposal/gate wording remained. `git diff --check` passed (exit 0); the scoped
`git diff --exit-code` for source, native code, tests, configuration, dependency
files and Phase 1/2 RFCs/reports was empty (exit 0). The worktree inventory shows
only TAY_PLAN.md modified and the already-existing untracked Phase 3 RFC updated.
No Mix compilation or tests were run for this documentation-only reconciliation.

**Documentation reconciliation complete. All six design gates are resolved;
stop pending separate source-implementation authorization. No Phase 3 source,
automatic repair, production payload design or later phase is implemented here.**
