# RFC: Phase 2 segment format, ownership, and rotation

Status: **proposed for review; no Phase 2 implementation authorized**.
Date: 2026-09-12. Scope: the first durable segment container and its creation,
append, sealing, and crash-visible lifecycle. This is a replacement proposal,
not approval of the 32-byte header or the original rotation sequence.

Normative inputs: [TAY_PLAN.md](../TAY_PLAN.md), the
[original candidates](storage-rfc-input.md), the
[adversarial requirements](phase-1-review-input.md), the
[approved record RFC](phase-1-storage-format-rfc.md), and the
[Phase 1 implementation report](phase-1-implementation-report.md). Record v1
remains exactly 24 header bytes, 28 overhead bytes, CRC32C as specified there,
and a 16,777,216-byte hard payload maximum. This RFC makes **no** change to
`Tay.Storage.Record` or `Tay.Storage.CRC32C`.

The proposed Linux `:sync` contract below is conditional on a local filesystem
actually honoring file and directory sync and advisory locks. A successful
system call cannot override a dishonest controller or failed hardware. macOS
may parse this byte format, but a power-failure durability claim there needs a
separately verified F_FULLFSYNC + directory-entry protocol (§16); `:sync` MUST
fail closed on an unverified platform. These platform restrictions are deliberate,
not permission to silently downgrade a requested durability mode.

## 1. Decisions and candidate assessment

Choose a fixed **44-byte header** and **64-byte footer**, plus a 28-byte immutable
`STORE` identity marker. Each multi-byte number and CRC integer is unsigned
big-endian. No padding, host-endian values, or runtime terms are written. There
are no optional v1 fields: every reserved bit/byte MUST be zero and is checked
after its containing checksum. All structural and checksum failures stop normal
startup without filesystem mutation.

The candidate 32-byte header's last four reserved bytes followed its CRC and
would be unprotected; it also had no way to identify a transplanted segment.
Retain its two *CRC-covered* reserved bytes and the useful `FIRST_SEQUENCE`,
replace the unprotected four bytes with a 128-bit store identity before a CRC
that covers **all** preceding bytes. The segment version is independent of
record framing version. A 16-digit decimal filename cannot represent all uint64
IDs; use exactly 20 digits (§5). The original create-next-directly sequence
could publish a canonical, partially written next header; use a staged file
and rename after syncing its header (§20).

## 2. Exact segment header: 44 bytes

Offsets are zero-based relative to the beginning of the segment file.
`H = bytes[0:40]`; all slices in this RFC are half-open.

| Offset | Width | Field | Legal v1 value |
| --- | ---: | --- | --- |
| 0 | 4 | `MAGIC` | ASCII `TAYS` = `54 41 59 53` |
| 4 | 1 | `SEGMENT_VERSION` | `1`; `0` invalid, `2..255` unsupported |
| 5 | 1 | `FLAGS` | `0`; nonzero unsupported mandatory flags |
| 6 | 2 | `RESERVED` | Both zero; nonzero corrupt after CRC verification |
| 8 | 8 | `SEGMENT_ID` | `1..2^64-1`; zero invalid |
| 16 | 8 | `FIRST_SEQUENCE` | `1..2^64-1`; zero invalid |
| 24 | 16 | `STORE_ID` | Exactly 16 nonzero-collectively opaque bytes; all-zero invalid |
| 40 | 4 | `HEADER_CRC32C` | `uint32_be(CRC32C(bytes[0:40]))` |

There is no field or reserved space at/after offset 44. `STORE_ID` is generated
from a CSPRNG once per new store, persisted in the marker (§4), and copied
bit-for-bit into every header/footer. It is an accidental cross-store mixing
detector, **not** a MAC, security token, or authorship proof. Never derive it
from filename, hostname, path, wall-clock time, job fields, or process PID.

The complete header is immutable. The CRC covers magic, version, flags,
reserved bytes, both coordinates, and all 16 identity bytes; do not zero out
fields or include the stored CRC in its own input. A new segment version is
required for a different layout/CRC/field meaning. Segment v1 contains only
approved physical Record framing v1; unknown Event type/schema IDs do not
change its segment version. A future *record framing* v2 requires explicit
segment compatibility review/new segment version, not a silent v1 fallback.

## 3. Exact sealed footer: 64 bytes

Footer offsets below are relative to its own start `F`, not the segment start.
The sealed footer MUST be the file's **last 64 bytes**; no padding or trailer
may follow it. Only a sealed segment has one. The footer is never interpreted
inside an opaque record payload.

| Offset | Width | Field | Legal v1 value |
| --- | ---: | --- | --- |
| 0 | 4 | `MAGIC` | ASCII `TAYF` = `54 41 59 46` |
| 4 | 1 | `SEGMENT_VERSION` | `1`; `0` invalid, `2..255` unsupported |
| 5 | 1 | `FLAGS` | `0`; other values unsupported |
| 6 | 2 | `RESERVED` | Both zero; other values corrupt |
| 8 | 8 | `SEGMENT_ID` | Same as header and canonical filename |
| 16 | 8 | `FIRST_SEQUENCE` | Exactly the header's value |
| 24 | 8 | `LAST_SEQUENCE` | `FIRST_SEQUENCE + RECORD_COUNT - 1`, checked without overflow |
| 32 | 8 | `RECORD_COUNT` | `1..38_347_918`, and no greater than format-derived physical bound |
| 40 | 16 | `STORE_ID` | Exactly header and immutable marker identity |
| 56 | 4 | `SEGMENT_CRC32C` | `uint32_be(CRC32C(file[0:F]))` |
| 60 | 4 | `FOOTER_CRC32C` | `uint32_be(CRC32C(file[F:F+60]))` |

For a sealed segment of count C, the actual records must be exactly sequences
`FIRST_SEQUENCE .. LAST_SEQUENCE` in byte order, C records, with no gaps,
duplicates, invalid individual records, or extra bytes. Validate equality of
the computed C/last with footer values **after** footer CRC, independent of the
header/segment CRC comparisons. The redundant FIRST/LAST/COUNT tuple checks
the header and catches mistakes in boundaries/sequence progression; LAST is
arithmetically derivable but materially strengthens independent footer-to-log
cross-checks. It cannot prove a missing acknowledged active tail was present.

Zero-record sealed segments are invalid. An empty *active* segment is exactly
the 44-byte header followed by EOF and contains no footer. Rotation never seals
an empty segment (§19). If the last sequence is `2^64-1`, a valid sealed final
segment may be terminal: do not try to represent `FIRST_SEQUENCE = 2^64`.

## 4. Immutable store identity marker: `data_dir/STORE`

An initialized store has exactly one ordinary, immutable regular file `STORE`.
Without it, a directory whose contents have been lost could be mistaken for a
new store. This is a minimal genesis anchor, **not** a manifest, sequence
checkpoint, snapshot, or evidence of the active-log tail length. A missing,
corrupt, or replaced marker in an initialized store is fatal; never silently
reinitialize it or infer a replacement identity from the surviving segments.
If an *already-existing* directory is now entirely empty, no disk bytes can
distinguish an intentionally empty new location from a completely erased old
store: do not automatically bootstrap it (§12). The marker cannot detect
erasure of the marker **and all other evidence**; explicit operator bootstrap
intent and dependable directory persistence are separate defenses.

| Offset | Width | Field | Legal v1 value |
| --- | ---: | --- | --- |
| 0 | 4 | `MAGIC` | ASCII `TAYI` = `54 41 59 49` |
| 4 | 1 | `STORE_VERSION` | `1`; zero invalid, other values unsupported |
| 5 | 1 | `FLAGS` | `0`; nonzero unsupported |
| 6 | 2 | `RESERVED` | Zero; nonzero corrupt |
| 8 | 16 | `STORE_ID` | A CSPRNG-chosen non-all-zero 128-bit value |
| 24 | 4 | `STORE_CRC32C` | `uint32_be(CRC32C(bytes[0:24]))` |

Require file size **exactly 28**. CRC protects every other marker byte. Reject
symlinks, hard links, directories, trailing bytes, and unknown version/flags.
The first segment and marker must agree; all later segment headers and footers
must agree with the same marker. Copying only a foreign segment with the same
numeric ID and sequence now fails, absent an identity collision or forged
bytes. Copying an *entire store including `STORE`* remains undetectable here.
Never rewrite `STORE` during rotation or mode changes.

## 5. Names, IDs, sequence anchors, and overflow

Canonical files live in `data_dir/segments/`. Filename is **exactly 20 ASCII
decimal digits** with leading zeros, then lowercase `.tay`; valid range
`00000000000000000001.tay` to `18446744073709551615.tay`. Reject uppercase,
extra suffix, 16-digit candidate names, and any overflow/zero ID. The header
ID MUST equal the filename ID; a valid CRC and a renamed copy do not excuse a
mismatch. IDs start at 1 and increase by exactly 1 without reuse; no rotation
if the next uint64 ID does not exist. No gap or duplicate is normal. A snapshot
may someday authorize a different observed starting ID, but only with its own
independently validated anchor (not a convenient remaining filename). Until
that design, discovery MUST begin at ID 1.

`FIRST_SEQUENCE` is the sequence assigned to this segment's first future record.
For a new store it is 1, even in an empty active segment. After preceding sealed
last P it is `P + 1`, checked before creating or accepting a successor. The
first record (when present) must equal the header anchor, subsequent records
advance by one across the area, and the footer repeats the first and records
the actual last/count. A last value of uint64 maximum can seal but cannot
have a successor. `FIRST_SEQUENCE` on an empty active header is a promise about
the **next** record, not evidence that an append already occurred. There is no
empty sealed LAST_SEQUENCE or COUNT convention because empty sealing is illegal.

For future snapshot replay beginning later than ID 1, the snapshot must attest
store identity, covered ID/sequence, prior boundary, and suffix expectation;
the first remaining segment cannot select an arbitrary starting point. This RFC
does not approve deletion/compaction, snapshot anchors, or per-record
`previous_sequence`.

## 6. Segment CRC: exact input and incremental state

Choose **option B = option C** in v1 (the header has no mutable fields):

```text
SEGMENT_CRC32C = CRC32C(
  all 44 bytes of immutable segment header ||
  every complete record byte in physical order,
  including each record's HEADER_CRC32C and RECORD_CRC32C
)
```

The checksum covers precisely `file[0:F]`, where `F` is the sealed footer start,
and nothing from the footer or unrelated files. It **includes** the stored
segment header CRC and both stored CRC fields in every record. Do not treat
any CRC byte as zero, XOR smaller CRCs, or finalize and resume a finalized CRC.
The writer starts a fresh Tay CRC32C register at the start of the header, updates
with exact successfully written chunks in order, then finalizes once when
forming the footer. A reopen/replay must recompute that register over readback
bytes, not trust a process-local cached register. A rejected/partial write
poisons the live writer; do not extend a guessed CRC state. Reading uses bounded
chunks; neither writer nor reader must load a whole segment to compute it.

This is a whole-segment, ordered-byte integrity check and can reveal altered
record bytes, insertion/deletion, or header replacement relative to an intact
footer. Per-record CRC/sequence and footer count/last catch many of the same
faults; this extra coverage does not give an independent cryptographic
probability, stop coordinated replacement with matching CRCs, prove a clean
lost suffix of an active segment, or reconstruct missing records. It is not a MAC.

## 7. Footer CRC and checksum precedence

`FOOTER_CRC32C = CRC32C(footer[0:60])` with **fresh** initial/final CRC state;
the stored footer CRC bytes `60..63` are excluded. This binds all footer
coordinates, the store identity, and the stored segment CRC before metadata
drives any acceptance. Segment CRC cannot cover its own containing footer
without a circular definition. Footer CRC does not authorize replay when the
record area or segment CRC fails.

Reuse the algorithm, initial state, and finalization of approved
`Tay.Storage.CRC32C` exactly; each header, store marker, footer, and whole
segment starts a separate checksum state. Fresh process or incremental chunk
boundaries must not change bytes. CRC32C is accidental-error detection, not
authentication. For the exact header/footer reading precedence see §10.

## 8. File-size format bound versus rotation policy

Propose a version-1 **hard complete segment file maximum of 1,073,741,824 bytes
(1 GiB)** including header and a sealed footer. The allowed active size is at
most `1,073,741,824 - 64` bytes to leave footer space. The writer must account
for `44 + sum(28 + payload_length) + 64`; a sealed one-record file is at least
136 bytes. The approved maximum-size record is 16,777,244 bytes; its full
segment envelope is **16,777,352** bytes. A reader rejects an out-of-format
file or declaration before allocating based on it, but streams valid files.

`rotation_target_bytes` is an *insertion-only* configuration (proposed default
67,108,864 = 64 MiB), range `16,777,352..1,073,741,824` inclusive, measured as
the potential complete *sealed* file size including the footer. It is NOT a
reader format limit; changing it cannot make historical segments unreadable.
Before a new record, rotate only when the current active contains at least one
record **and** `current_file_size + record_bytes + 64 > rotation_target_bytes`.
For an empty active, any legal v1 record fits the minimum target; no empty
sealed segments are needed. Equality fits. Independently enforce the 1 GiB
hard bound, even if the configuration is larger/invalid. Four maximum-size
records do **not** fit the 64 MiB default (their record bytes total
67,108,976, or 67,109,084 bytes with header and footer); three do. A rotation
threshold is not an on-disk field.

The hard 1 GiB bound makes reader resource planning finite and intentionally
restricts v1; increasing it for *stored* files requires a reviewed segment
version. A smaller decoder resource budget may stop processing operationally
but cannot classify a valid historical file as corrupt or grant repair rights.

## 9. Deterministic boundaries and active/sealed classification

At known offset 44, parse complete v1 records sequentially, advancing only by
their validated `28 + N`; do not search for magic in arbitrary bytes. At each
**known record boundary**, `TAY\x00` begins a record, `TAYF` begins a potential
footer, and EOF completes an active segment. A footer is accepted only if it
begins exactly 64 bytes before physical EOF, passes §7/§10, and all preceding
records completely validate. A footer-like substring in any payload is opaque.
An actual footer followed by random bytes, a duplicate footer, or a footer at
the wrong boundary/offset is corruption; never accept a valid prefix and ignore
the rest. `TAY` with fewer than four bytes at EOF is ambiguous between an
incomplete record and footer, not permission to truncate.

Before any future manifest, all segments **except the highest** must be fully
sealed. The highest may be exactly a valid active header plus zero or more
complete records **within the 1 GiB minus 64-byte active bound**, or it may
be valid sealed with no successor yet (crash after
sealing). If the highest is sealed and last < uint64 maximum, a writer holding
the store lock may durably create the next empty active by §20. If last is the
uint64 maximum, the store is valid but permanently read-only/exhausted. A
highest empty active is valid. Earlier empty-active, zero-byte canonical file,
earlier partial footer, partial record, or unvalidated footer is fatal. A
truncated highest tail is **classified**, not repaired by Phase 2 (§25).

No such classification implies that the stored prefix contains all records ever
acknowledged. Phase 3 owns any tail-repair authorization; a clean valid active
suffix loss remains undetectable (§27).

## 10. Reader validation order and result contract

This RFC specifies the behavior of a future physical `Segment` parser and a
file-backed `Reader` without selecting their Elixir function names. Each must
return a tagged **classification** (including exact segment ID and offset) or
explicit I/O/resource failure. An error, unsupported value, or incomplete
suffix returns no accepted remainder/repair action; neither layer alters files.

Validation order is normative when multiple faults coexist:

1. Validate caller arguments, open a *regular* file safely, and obtain its
   identity, size, filename ID, and owning `STORE` under §§11–13. I/O or
   unsupported filesystem capabilities are not disk corruption.
2. A mismatching observed `TAYS` magic byte is corrupt immediately; short
   matching prefix is incomplete header. With byte 4 available, zero version is
   invalid and `2..255` unsupported **before assuming the v1 44-byte layout**.
   Require 44 bytes before reading other v1 fields.
3. Verify the header CRC over bytes `0:40` before trusting ID, first sequence,
   store identity, or any variable byte count. Then validate flags, reserved
   bytes, nonzero ID and FIRST, nonzero STORE_ID, filename ID equality, and
   marker identity, in that order. File size above 1 GiB is format corruption.
4. Stream records from offset 44. At each known boundary compare the magic
   prefix (`TAY\x00` versus `TAYF`), with short `TAY` recorded as ambiguous
   incomplete. Use the Phase 1 Record decoder's precedence, hard limit, and
   bounded resource option exactly; propagate its corrupt/unsupported/resource
   classification **without turning it into torn-tail permission**. Confirm
   individual sequences, starting at FIRST, but do not interpret Event payloads.
   Maintain a fresh segment CRC over exact header and complete record bytes.
5. At EOF on a record boundary, classify physically valid active **only if**
   the active file size is at most `1,073,741,760` bytes; it is legal only
   for the highest ID. An incomplete record/header/footer-like prefix
   classifies incomplete only on the highest; in an earlier segment it is a
   sealed-history error. A complete `TAYF` at a boundary requires exactly 64
   bytes through EOF; otherwise trailing/duplicate bytes are corrupt, or the
   short footer is incomplete if EOF falls inside those 64 bytes.
6. For an exactly placed complete footer, check its first four magic bytes and
   version before v1 offsets. Verify `FOOTER_CRC32C` over the fixed 60 bytes
   **before trusting** its count, last sequence, stored segment CRC, or
   identity. Then validate flags, reserved, numeric ranges, header/filename
   ID, repeated FIRST, marker/header identity, checked count/last relation,
   observed count/last, and the full segment CRC, in that order. Never accept
   a partial record area just because the footer's CRC is good.
7. Apply store-wide IDs/continuity and active/sealed ordering (§9/§11). Only
   after all required physical validation may a *future* replay path validate
   Event type/schema/payload and project it. Physical success is not startup
   readiness, durable acknowledgement, or an applied checkpoint.

The parser reports `:incomplete_segment_header`, `:incomplete_record`,
`:incomplete_footer`, or `:ambiguous_short_tail` with offset, available bytes,
and expected bytes where known. Other categories distinguish
`:corrupt_segment_header`, `:corrupt_footer`, `:segment_crc`,
`:record_or_sequence_error`, `:id_or_store_mismatch`,
`:discovery_error`, `:unsupported_segment_version`, and
`:io_or_resource_error`. Nested Phase 1 Record reasons remain intact. These
are conceptual category names, **not** an unapproved public stable API or
truncation recommendation. A full footer with bad CRC is corrupt, not a clean
active ending; an unsupported segment/footer version stops without fallback.

## 11. Directory discovery and ownership of names

Read the *complete* `data_dir/segments/` directory listing, including unusual
raw names on platforms where available. Sort canonical IDs numerically and
require `1..highest` with no holes. Do not invent an active segment from an
incomplete prefix or missing entry; do not renumber. A name ending in `.tay`
but not the exact 20-digit pattern is an error, not unrelated data. An apparent
duplicate ID (alternate spellings, case, duplicate content via aliases) is an
error. Refuse symlinks/special files anywhere used as a canonical segment,
marker, lock, or staging file. Refuse hard-linked canonical segments/marker;
stat the opened object as well as the inspected name to detect substitution.
Directory and parent symlink traversal is unsupported; validate components and
use fd-relative/no-follow native operations so validation cannot be bypassed by
a path replacement. An inability to list, stat, open, read, or inspect any
required file is an operational startup failure, never an empty store.

Reserve staging names of the exact form
`.tay-new-<20-digit-id>-<32-lowercase-hex-nonce>.tmp` inside `segments/` and
`.tay-store-<32-lowercase-hex-nonce>.tmp` inside `data_dir/`. These are created
exclusively and **never contain records**: at most a segment header (44 bytes)
or a marker (28 bytes), respectively. A stale recognized staging file of size
no greater than its cap may remain without being replayed or automatically
deleted; a longer file, symlink, unexpected type, or malformed *reserved-prefix*
name is a hard discovery failure. Staged bytes, even if fully valid, do not
establish an additional active segment. Ordinary unrelated files not using
`.tay` or reserved prefixes may be ignored in `segments/` after type inspection,
but cannot be mistaken for history. A directory where a segment file is
expected, permission loss, or a zero-byte canonical `.tay` is fatal. No wildcard
search for a later good file is allowed.

Outside initialized stores, a wholly empty new `segments/` directory can only
occur in the explicitly unfinished genesis states of §12. With an existing
valid `STORE` it means missing history and fails; the marker is never rewritten
to make an apparently empty directory acceptable. A missing highest *active*
segment while all earlier sealed segments remain is **not in general
detectable** from their contents; this RFC does not pretend otherwise (§27).

## 12. Bootstrap and the independent genesis anchor

The configured data directory is required for Phase 2 (Phase 0's provisional
dev/test defaults do not become a production storage-location contract).
Automatic new-store creation is legal only when Tay itself has just created a
previously nonexistent `data_dir` in this startup; if the directory **already
existed** without `STORE`, even if empty or containing only a lock/staging
file, fail closed unless the operator explicitly requests one-time bootstrap
after verifying it is not a lost prior store. That intent authorizes only an
empty root (apart from Tay's lock/staging names) and empty `segments/`, not
reinitialization over any canonical file or unknown entry. The narrowly
proved bare ID-1 header-only missing-marker state below may be completed
without such intent because this protocol forbids records before the marker;
this relies on the same honored sync assumptions as record acknowledgements.
Creating it and missing parent directories requires checking each component
is a real directory and syncing each new child's parent before any durable
acknowledgement. The narrow creation of a previously absent `data_dir` and
its lock-file inode must precede acquiring that lock; no initialized-store
metadata or segment may be inspected or changed in this window. Hold the
directory lock (§13) for all later steps. Create `segments/` and sync
`data_dir/`. Sync a newly created lock-file inode and its `data_dir/` entry
before any acknowledgement; the helper holds that inode's lock throughout.
For a genuinely new empty store, generate a nonzero 128-bit ID once, then:

1. Exclusively create a random staged ID-1 file; write only its 44-byte header
   (`FIRST_SEQUENCE=1`), verify exact bytes, sync file.
2. Atomically rename to canonical ID 1 without replacing an existing name; sync
   `segments/` directory. No record may yet be appended.
3. Exclusively create a staged 28-byte `STORE` with the **same** ID; write,
   verify, sync, atomically rename without replacement, sync `data_dir/`
   directory.
4. Revalidate the canonical header, marker, identity, and directory invariants
   under the same lock. Only then mark the empty segment writable/ready.

Crash before step 2 leaves no canonical segment; recognized short staging files
may be ignored, but initialization on the now pre-existing directory requires
explicit one-time bootstrap intent before retrying with a fresh ID. Crash after step 2
but before durable step 3 may leave a **single** canonical ID-1 header-only
file and no marker; this unique state can finish creating the missing marker
from the validated header ID, because the protocol forbids all record writes
before marker publication. It must have no other canonical segment, no record,
no footer, no malformed entry, and must pass all header/identity checks.
Anything else without `STORE` fails closed; never infer an identity from a
multi-record/multi-segment history. If the marker is present but its directory
sync was interrupted, verify both objects and sync the parent before any new
record; if the marker disappears on another crash, no record has yet been
acknowledged. Once marker and first segment have been durably published,
losing all canonical segments is fatal, not fresh initialization.

Failure at any bootstrap step never produces an insertion acknowledgement.
Normal retry after an unambiguous short staging file or bare header-only ID 1
does **not** truncate/delete it and cannot erase acknowledged records. It
does not authorize general repair of an existing initialized store.

## 13. Single-writer process and cross-BEAM ownership

One Tay writer actor owns every in-memory sequence candidate and operation
state. OTP supervision alone cannot prevent two **OS** processes from writing
the same directory. Except for the narrow absent-directory/lock-inode
creation in §12, before inspecting or mutating initialized-store metadata or
segments acquire a nonblocking OS exclusive advisory lock on the fixed inode
`data_dir/.tay-owner.lock`. This
ordinary persistent lock file MUST NOT be deleted, renamed, or truncated during
normal operation; a stale *file* after a crash is fine because the **OS lock**
is released on descriptor close. PID files, `O_EXCL` lock-file creation alone,
`:global`, and mere `Tay.Supervisor` registration do not meet the requirement.
Refuse symlink/hardlink lock-file aliases and unsupported/network filesystems.
Content of this file has no storage semantics and is never a store identity.
If the lock file had to be created, its own file and parent directory must be
synced before any successful insertion, in addition to the bootstrapping
barriers of §12. Failure to preserve its pathname fails readiness.

The proposed portable Linux/macOS integration is a small, supervised native
Port helper using `flock(LOCK_EX | LOCK_NB)` on an FD held for its whole lifetime.
It must own the **only** writable segment FDs and execute the serialized,
offset-explicit create/write/sync/rename/directory-sync operations in §§12–20.
The BEAM process never writes segments directly: if the helper loses its lock,
it cannot continue writing or grant a new success while another BEAM takes
ownership. An IPC disconnect/timeout is an *uncertain* outcome and poisons the
BEAM writer; never infer that an operation failed or succeeded. The helper
closes descriptors and exits on parent death/pipe EOF; an orphan that remains
locked only delays liveness, not correctness. Helper replies with operation ID,
verified lengths, sync results, and errors; the BEAM must not acknowledge until
the matching completed response. No NIF is required for checksum computation.
Native helper packaging and sandboxed runtime capability must be reviewed before
Phase 2 implementation, but neither introduces an unreviewed on-disk field.

`flock` is advisory: every Tay writer/maintenance process MUST cooperate;
unrelated hostile writers and external unlink/replace attacks are outside this
accidental-corruption threat model. Check that the lock path still refers to
the held inode before publishing readiness and after each potentially lengthy
operation; failure poisons the writer. A second BEAM must receive a clear
`:store_busy`-like error and must not even perform startup repair. A reader
used for recovery before writer readiness runs under the same lock. A
separately designed read-only inspection tool may avoid the lock but cannot
mutate or assert a stable concurrent view.

Linux [flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html) and Apple
[flock(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html)
describe nonblocking exclusive advisory locking; [OTP file.open/2](https://www.erlang.org/doc/apps/kernel/file.html)
documents exclusive *creation*, not an equivalent persistent OS lock. No
supported writer proceeds if its lock backend is unavailable or its lock is lost.

## 14. Sequence allocation and append commitment

The next sequence is a **candidate** derived from the last fully validated
record of the active segment, or the prior sealed footer for an empty active.
Compute it with checked uint64 arithmetic; refuse at exhaustion. Validate
inputs and room/rotation *before* encoding a final record with that candidate.
There is no separately persisted sequence counter and no reserved-but-missing
sequence gap on disk. Writer never appends a second record while the previous
append/rotation outcome is uncertain.

If validation or capacity checking fails before I/O, no candidate is consumed;
the same number remains available. An I/O failure **even before any known
bytes were written** poisons the current writer rather than blindly allocating
the next number; restart under the lock must validate the actual bytes. A
partial append leaves an incomplete record, is not accepted, and must not be
overwritten by reusing its number until the separate Phase 3 repair policy
authorizes a safe tail action. A complete record with failed sync, crash, or
lost response may exist: never append a *different* record with its sequence.
On a subsequent validated restart the complete frame occupies its sequence,
even if the prior caller never saw success. An ambiguous append must be
reported as uncertain, not advertised as a definite no-write failure.

For `:write`, physical commitment in the live process occurs only after the
full byte count is independently observed as written. For `:sync`, durable-mode
commitment occurs only after successful file sync and all required file/directory
publication barriers. Neither is Event acceptance or a projected job checkpoint.
If a sync succeeded but the response was lost, the caller cannot safely
reissue insertion as a new record and assume exactly-once: reconciliation or a
future stable application idempotency key belongs to the payload/insertion RFC.

## 15. One-record append protocol and error states

Under a held store lock and validated, published canonical active header:

1. Accept an already application-validated **opaque event representation** at
   the storage boundary; the Phase 2 internal writer must not pretend a raw
   arbitrary `Tay.Storage.Record` is semantically approved for production.
   Phase 2 tests may use physical test identifiers without defining real Events.
2. Check `uint64` sequence/segment headroom and approved Record type/schema
   structural constraints; decide rotation from the final encoded record length
   and §8. Complete any needed rotation/durability barriers *first* (§20).
   Recompute the candidate next sequence using the new active header; encode
   the immutable Record with the Phase 1 codec. No record crosses a file.
3. Issue a single offset-explicit append request at the expected physical EOF,
   under the helper's exclusive lock. No overlapping writes or fallback to
   implicit file-position append. Compare reported written bytes, resulting
   file extent, and (where the OS API cannot report partial counts) bounded
   readback at the same offset against the **exact** encoded bytes. `:ok`
   without full verified length is not a complete append.
4. In `:sync` mode, request file `fsync` and require success before any durable
   success reply. No delayed-write buffering, compression, text translation,
   or `fdatasync` substitution without reviewed platform proof. In `:write`
   mode, a fully verified write may return a *best-effort* result without file
   sync. Maintain raw segment CRC state only for known fully written bytes.
5. Publish only the matching result to the caller; the future runtime/ETS
   projection and readiness must independently await Event and replay rules.
   Never report a persisted job merely because the physical codec succeeded.

No retry of a short/error/unknown-count write is automatic in v1, even at the
remaining offset. A known count could theoretically support an offset-pinned
retry, but this RFC deliberately avoids an implicit retry whose first operation
may have advanced unpredictably. An interrupted syscall with independently
proved zero bytes may be *diagnosed* as zero, but an I/O error still poisons
the writer. Never turn `EINTR`, `ENOSPC`, `EIO`, permission loss, descriptor
closure, helper crash, or sync failure into an acknowledgement. Freeze appends,
retain bytes, propagate an error or `:uncertain`, and require locked reinspection
on restart. Do not truncate/overwrite on the live failure path.

If the caller loses its response after a successful sync, the record may be
durable but unacknowledged at the API boundary; neither automatic retry nor
discard is safe without application identity. Conversely `:write` may have
returned before an OS crash removes the tail. These distinctions must appear
in future user-facing insertion semantics (§27).

## 16. Durability modes and supported platforms

Propose only `:write` (best effort) and `:sync` (durable-mode attempt), not
`:none`/`:flush`: v1 deliberately has no Erlang delayed-write buffer to flush,
and those names would conceal whether an OS persistence barrier happened.
No mode is added to `Tay.Config` by this RFC; the future default must be
`:sync` on a verified supported platform and otherwise startup fails without
falling back. Changing a mode never changes how historical valid bytes decode.

| Outcome | `:write` after a verified full write | `:sync` after file and required directory sync |
| --- | --- | --- |
| Writer actor or helper crash | OS-buffered bytes *may* survive; no guarantee when I/O was uncertain | Previously acknowledged bytes remain available if OS/storage assumptions hold |
| BEAM crash / normal process termination | Completed OS writes usually remain in the living kernel, but not a promised recovery substitute for fsync | Previously acknowledged bytes survive a restart under the same supported OS/filesystem assumptions |
| OS crash or power loss | Any acknowledged best-effort tail may vanish; only validate what remains | Previously acknowledged bytes and requisite pathnames survive if each sync and ordering barrier was honored by the filesystem/device |

Regardless of mode, **sealing/rotation/first publication** perform the full
file and directory barriers in §§12/20, or stop; otherwise creation of the
next segment could hide previous history after crash. `:write` is not
acknowledged durability under TAY_PLAN invariant A and must never be presented
as such. A successful `:sync` reports successful requested durability syscalls,
not mathematical proof that hardware honors them; sudden media destruction,
lying flushes, uncooperative writes, and remote mounts are outside this v1
contract.

The proposed supported strict-durability target is Linux with an explicitly
validated **local** filesystem/device that honors ordinary `fsync` for files
and directories, atomic *no-replace* same-directory rename, `O_EXCL`, and
`flock`. NFS,
SMB, distributed/overlay mounts without verified equivalent semantics, and
filesystems returning unsupported/no-op sync are rejected for `:sync`.
`file:sync/1` can be used only where it demonstrably provides the required
native fsync; the same native helper may call `fsync` directly. On macOS,
Apple documents that plain `fsync` need not flush drive caches across power
loss and recommends `F_FULLFSYNC`. **Until** a platform adapter verifies both
file F_FULLFSYNC and durable directory-entry handling on the target filesystem,
macOS is not supported for this `:sync` guarantee; development-only `:write`
may be available if locking and safe structural barriers themselves work.
Never silently substitute plain `file:sync` for macOS power-loss durability.

Publication MUST be one atomic **no-replace** operation on the destination,
for both canonical segment names and the immutable `STORE`. On Linux use
fd-relative `renameat2(..., RENAME_NOREPLACE)`; require underlying-filesystem
support. On macOS a future adapter must establish support for
`renamex_np(..., RENAME_EXCL)` as well as its separately required durability
barriers. An `exists?` precheck followed by ordinary `rename` is **not** an
equivalent: ordinary rename may replace a concurrently created canonical
segment or the immutable marker, losing acknowledged history. Unsupported
no-replace calls fail startup/rotation; no fallback to replacing rename, even
when the OS lock is held (another process or tool may not cooperate).
[Linux rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html)
specifies both ordinary replacement and `RENAME_NOREPLACE` filesystem support;
[Apple volumeSupportsExclusiveRenaming](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumesupportsexclusiverenaming)
documents `RENAME_EXCL` capability.

[Linux fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html) requires
separately syncing a directory for a new filename; [Apple fsync(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)
warns about the drive cache and describes `F_FULLFSYNC`. OTP
[file.sync/1, datasync/1, and open options](https://www.erlang.org/doc/apps/kernel/file.html)
also warn about platform differences and delayed-write error deferral. Tests
must validate the actual chosen adapter; a feature name alone is not proof.

## 17. File and directory sync dependency chain

Every `:sync` acknowledgement depends on these already successful barriers:

| Operation | Required ordering before a new durable acknowledgement |
| --- | --- |
| Create a new directory component including `data_dir` | Create, verify no symlink, sync the *parent* directory; then sync the child if needed before publishing files beneath it |
| Create `segments/` | Sync `data_dir/` after the new entry, before any ready segment |
| Create first segment and immutable `STORE` | Sync each temp file; atomic no-replace rename (§16); sync its containing directory; validate both, in §12 order |
| Append a record to existing published active | Verify full bytes; sync the active file for `:sync`; no directory sync if only file contents changed and its entry was already durably published |
| Seal old active | Write complete footer; sync **old segment file** before creating/publishing a successor; no directory entry changes yet |
| Create/rename new segment on rotation | Sync staged header file; atomic no-replace rename (§16); sync `segments/`; no append before successful directory sync |
| Temp/marker rename or new file | Sync file contents before rename and parent directory after rename; if replacing ever approved later, sync both affected parent directories as needed |

This is a partial-order contract, not a claim that merely calling `fsync` on a
new segment persists its name. Do not acknowledge a record in that newly
published segment until the old sealed footer, its own header, its canonical
directory entry, and its eventual record data have all crossed their required
barriers. Sync error anywhere stops progress; absence of a later successfully
sync'd directory entry is not evidence that a returned earlier `:sync`
acknowledgement can be safely replayed if the filesystem violates its contract.

## 18. Short writes, fault injection, and bounded I/O

An OS call may write fewer bytes or fail after modifying the file. The native
helper's explicit offset operation must expose `bytes_written` when knowable;
when an OTP write returns only `:ok`/`{:error, reason}`, a writer cannot assume
that a failed call wrote zero bytes. A successful call must still verify exact
resulting extent and read back its designated range if necessary. The helper
pins the FD/inode, serializes writes, and forbids concurrent aliases. Refuse
append if observed EOF differs from the expected offset or an unexpected file
extent appears. No second append after a partial/uncertain one.

The reader uses a fixed 44-byte header buffer, a fixed 64-byte footer buffer,
and a bounded per-record read no greater than `28 + 16_777_216` bytes under the
Record resource budget. It can first read a 24-byte Record header, validate
its header CRC and hard bound, then read the remaining bytes in bounded chunks;
the streaming segment CRC incorporates the exact raw bytes. No whole-file
buffering is required to validate a 1 GiB segment, and a huge record is never
allocated from unchecked length metadata. Validate file size and offset
arithmetic before additions. Descriptor/open/read/short-read failures are
operational errors distinct from disk corruption when the syscall itself
reports an error; EOF at an invalid place is a physical incomplete/corrupt
classification, never automatic repair.

## 19. Footer preparation and empty-segment rule

To seal, require `count >= 1`, all appended records fully accounted for, and
an unpoisoned writer. Freeze appends at a known record boundary; compute
`LAST_SEQUENCE` from verified actual records, not from a request counter;
compare observed last/count/CRC with incremental state and, after uncertainty,
rescan rather than guessing. Construct the full 64-byte footer and its own CRC
in memory, append at the exact current EOF, verify complete footer bytes,
and sync the entire old file **before** proceeding. Close the old writable FD
after successful sync and before opening any new canonical segment for writing;
any close error is uncertain and poisons the writer. Once sealed and validated,
never append another byte to that inode. Any failure poisons the writer;
Phase 2 does not remove a partial footer. If the active is empty, bypass
rotation and keep it active; a request to seal an empty active is rejected.

## 20. Replacement rotation protocol: exact transitions

Only an unpoisoned writer holding the lock may start rotation, and only if it
can represent both `old_id + 1` and `old_last_sequence + 1`. Starting with a
**nonempty** canonical active `A` durably published in the directory:

| State | Action; required success before next state | Possible durable-visible files |
| --- | --- | --- |
| R0 | Freeze new requests; validate A, last sequence, target capacity, and EOF | A active; no next canonical |
| R1 | Append and verify one complete 64-byte footer to A at known boundary | A may have absent/partial/full *unsynced* footer |
| R2 | Sync A's file including footer; verify success, then close A's writable FD | A sealed, durably under supported fsync contract; no old writable FD |
| R3 | Exclusively create `.tay-new-<next-id>-<nonce>.tmp`; write only 44-byte next header with `FIRST=old_last+1`, same STORE_ID; verify exact bytes | A sealed; temp may be absent/partial/full; no new canonical |
| R4 | Sync temp header's file; require success; close temp writable FD and verify its path/inode | A sealed; complete durable temp header; no open writable segment FD |
| R5 | Check next canonical absence, then perform an atomic, fd-relative same-directory **no-replace** rename (§16); any existing destination fails even if the earlier check saw absence | A sealed; next canonical may appear, or only A may remain after crash |
| R6 | Sync `segments/` directory; revalidate new header/inode/path, lock, and contiguous anchors | A sealed; next empty active is durably published |
| R7 | Open only the new canonical as writable, switch in-memory active ID/CRC state, accept next request | A sealed and next active; no bytes written to temp; only one writable canonical FD |

Never create the next canonical name directly and write a partial header into
it. Never publish a next record or a `:sync` success before R6. A failed rename
must not overwrite any target: fail/poison if it exists or the no-replace
operation is unsupported. Prior A's footer must
be synced **before** even creating the temp file so that finding a successor
requires a previously completed old sealing barrier. Startup neither requires
nor trusts a process-local R-state: it decides using validated on-disk bytes.
The temp file never holds records; there are never two writable *canonical*
segments. No old segment is deleted or truncated at any transition.
A close result may not itself be substituted for any required prior successful
sync; a close error/unknown response poisons the current writer. A restarted
reader opens sealed history read-only and never reopens an older canonical
segment with write access.

After R7 the next append follows §15 and, under `:sync`, independently syncs its
record bytes. An explicit shutdown may leave a valid active (including an
empty one); there is no requirement to seal it on close. A highest sealed
segment with no successor is a recoverable, valid interrupted rotation state,
not a reason to label its footer corrupt or to treat it as active.

## 21. Rotation crash matrix and restart actions

Every classification below assumes the lock is re-acquired and all visible
canonical segments/`STORE` independently validate. `:fail` means **no startup
write/readiness**, not automatic truncation. A visible staged file is ignored
only under the strict no-record/size/type rules of §11; it is never deleted by
normal startup.

| Crash/error window | Possible on-disk observation | Classification and safe Phase 2 action |
| --- | --- | --- |
| Before footer write (R0) | Highest A has complete records and EOF | Valid active A; reopen under lock if all records/anchors pass |
| During footer write (R1) | EOF at a partial `TAYF` / ambiguous `TAY` at record boundary | Incomplete/ambiguous highest suffix; **fail**, do not truncate; Phase 3 decision |
| During footer write with damaged non-prefix bytes | Neither valid record nor valid footer | Corrupt or ambiguous data; **fail**, no resynchronization |
| After full footer write, before old-file sync (R1→R2) | Full valid footer, or footer/tail lost or damaged by crash | If full segment/footer valid: treat A sealed; if clean valid EOF at record boundary: treat A active; otherwise **fail**. Never invent a record or delete a footer |
| Old-file sync failed or helper response unknown (R2) | Same possibilities; no new canonical allowed | Live writer poisoned; on restart use actual validated A state as preceding row, or **fail** |
| After successful old-file sync, before temp creation (R2→R3) | Highest A sealed, no successor | Valid sealed-high state; create next empty active by R3–R6 unless sequence/ID exhausted |
| After next-temp creation, before complete header (R3) | A sealed; short staging file only | Ignore verified-size temp **without deleting**; retry with a fresh nonce |
| After complete temp header, before file sync (R3→R4) | A sealed; staged header present/absent/partial | Same, no canonical next; new nonce after validating A |
| After successful temp sync, before rename (R4→R5) | A sealed; complete staged header | Same; temp cannot contain an acknowledged record |
| During/after rename, before directory sync (R5→R6) | A sealed; new canonical may exist as a **complete** empty header, or be absent | If visible/valid, sync `segments/` under lock before allowing writes; if absent, create it anew. An incomplete/mismatched canonical is **fail**, not an orphan to delete |
| Directory sync failed or reply lost (R6) | A sealed; canonical new header may be visible | Poison live writer; revalidate/resync if intact on restart; **fail** if invalid; no prior next-record acknowledgement exists |
| After directory sync, before appends (R6→R7) | A sealed, next canonical valid empty active | Reopen next active; it has FIRST but no used sequence |
| During first record after R7 | A sealed, next active with valid/partial/absent first record | Full valid record follows §14; absent bytes leave empty active; partial bytes are classified and startup **fails** pending Phase 3, never deleted automatically |

Crash between any two steps never justifies deleting/truncating the old sealed
file, a canonical new file, or a partial footer. In the valid-highest-sealed
case automatic **creation of a new header-only** successor (R3–R6) is safe:
it cannot discard prior bytes and requires checked ID/sequence successor and
validated `STORE`. The one exception at sequence maximum is read-only terminal.
If an earlier segment is partial or invalid, even a perfectly valid highest
segment does not make startup recoverable.

## 22. Footer/torn-tail and random-tail discrimination

| Final bytes at a known record boundary | Physical classification | Phase 2 action |
| --- | --- | --- |
| `[valid records][EOF]`, highest | Valid active (possibly empty); no proof of lost-suffix absence | No repair; may reopen if entire store validates |
| `[valid records][partial Record][EOF]`, highest | Incomplete record with Phase 1 result/offset | Fail startup for now; Phase 3 determines if any repair is justified |
| `[valid records][TAYF prefix shorter than 64][EOF]`, highest | Incomplete footer (under 4 bytes `TAY` is ambiguous) | Fail startup; no guessing that it was only a seal attempt |
| `[valid records][valid 64-byte footer][EOF]` | Sealed after footer CRC, segment CRC, anchors, and count pass | Only then may be earlier or highest sealed |
| `[valid records][valid footer][random tail]` | Footer not at EOF-64, or unrecognized bytes after it | Fail; never ignore or delete the random suffix |
| `[valid records][footer][footer]` | Duplicate/extra footer | Fail; sealed footer is unique and final |
| `[valid records][damaged full footer]` | Footer checksum/metadata/segment-integrity failure | Fail even if the valid record prefix ends at a plausible boundary |

The physical parser knows record boundaries and which segment is highest. It
does not know whether an incomplete sequence came from an interrupted append,
an interrupted seal, media damage, or a corrupted length with coincidental CRC;
even a high-confidence *classification* is not a repair authorization. Phase 3
must prove its recovery preconditions separately. Sealed-history failure is
never treated as a disposable active tail.

## 23. Cross-store substitution, missing IDs, and detection limits

For `[1 sealed, 2 sealed, 3 active]` becoming `[1, 3]`, the filename ID gap
fails before projection. An additional `2-copy.tay`, a short name, or a second
canonical alias causes malformed/duplicate discovery failure. Renaming a
valid segment-2 file to `...00003.tay` fails internal/filename ID equality.
Copying another store's ID-3 file to the expected name fails STORE_ID against
both marker and earlier segments, even if its sequence and CRCs match. Copying
a whole foreign store including its `STORE` cannot be detected by this file
format alone; CRC is not authentication or protection against a malicious
writer able to recompute checksums.

Cross-store substitution is **in scope for accidental mismatched-segment
detection** and justifies the immutable identity marker plus repeated header
and footer identity. It is not a cryptographic authenticity guarantee. Missing
the very first segment now fails with the marker still present and no validated
genesis, rather than reanchoring at a later filename. An entire lost highest
active segment when earlier files are all sealed can resemble an interrupted
rotation *before* the next was created; the retained metadata cannot prove
that the missing segment ever existed. Sync publication, not redundant IDs,
is the protection for acknowledged writes under the supported failure model.

## 24. Active-tail clean suffix loss

Suppose active physical records 100, 101, 102 existed and a `:sync` success for
102 was returned, but later the file contains only 100, 101, EOF. The header,
remaining Record CRCs, and sequence continuity all validate. An active segment
has no footer, so neither a stored LAST/count nor a segment CRC is available
to detect the missing final suffix. A sealed footer *could* detect deletion
from previously sealed history if its own bytes survive. The immutable `STORE`
also carries no active high-water coordinate. Additional durable metadata,
with its own update/ordering protocol, would be necessary to **detect** this
active case from surviving bytes. It still could not reconstruct record 102.

For supported `:sync`, this case violates the assumed successful file-sync
behavior (or external disk/mount tampering): file bytes containing 102 were
synced before the acknowledgement and the containing segment pathname was
previously directory-synced. The RFC must not promise discovery if those
assumptions are broken. For `:write`, loss is an explicitly accepted outcome.
No timestamp, footer for unrelated sealed segments, or CRC over the surviving
prefix solves information that is entirely absent.

## 25. Parser classification is not repair authorization

The *Segment* layer may classify a short active header, record, footer prefix,
discovery anomaly, or checksum mismatch; *Reader* passes those results along
with known offsets/observed bytes. Both remain read-only with respect to
existing history. Phase 2 Writer creates new segment headers only in the
proved, valid highest-sealed state, or completes the narrowly proved
no-record genesis publication of §12. Neither may delete, truncate, zero,
rewrite, rename an existing canonical file, or publish partial recovery.
Recognized stale temp files may be ignored but not removed as a side effect.

Phase 3 Recovery must separately specify evidence needed to repair a truly
incomplete active tail, whether a torn footer can ever be removed safely,
active-versus-sealed history, prior acknowledged sync barriers, and commit
state. Even an `:incomplete_footer` at the highest segment is insufficient
by itself; `:unsupported_segment_version` or later unknown Event semantics
must leave storage untouched. A physical cursor past a Record is not a
semantically applied replay checkpoint.

## 26. Adversarial classification matrix

Here `fail` means refuse writer startup/semantic readiness, keep storage
untouched, and report exact ID/offset/reason. `defer` means classify and pass
to Phase 3 **without automatically changing bytes**. No case silently skips
a required segment, record, or footer.

| Fault | Detectable and classification | Safe automatic Phase 2 action; startup? |
| --- | --- | --- |
| Single-bit header field/CRC mutation | Invalid magic/version or header CRC; never trust damaged ID/FIRST | None; fail |
| Header ID differs from filename | Yes after header CRC | None; fail |
| Header FIRST zero/gap, store ID mismatch | Yes structurally/marker/adjacent anchor | None; fail |
| Torn canonical header or zero-byte canonical | Yes as incomplete/header failure | None; fail (except proved bare ID-1 genesis state, which requires a **complete** header) |
| Pre-existing now-empty directory and absent `STORE` | Cannot distinguish virgin directory from total erasure | Fail absent explicit one-time operator bootstrap intent; never silent reinitialization |
| Nonzero header reserved bytes with matching CRC | Yes; reserved corruption | None; fail |
| Footer field/CRC single-bit mutation | Yes as footer CRC, except early version/magic precedence | None; fail |
| Footer ID/FIRST/LAST/count/store mismatch with recomputed footer CRC | Yes by header, store marker, record-derived count/last | None; fail |
| Segment CRC corruption with valid footer CRC | Yes by independently recomputed whole segment CRC | None; fail |
| Torn/missing sealed footer in an earlier segment | Yes from earlier-than-highest ordering | None; fail, never relabel active |
| Missing footer of highest when bytes otherwise form valid active | **Not necessarily** detectable: highest may legitimately be active | No repair; may open active only under supported sync assumptions |
| Torn highest footer or 1–3-byte ambiguous prefix | Yes incompleteness; cause unproven | Defer; fail until Phase 3 policy |
| Duplicated footer or random bytes after it | Yes at known boundary/EOF | None; fail, no skip |
| Missing/duplicate/reordered segment IDs | Yes when present in directory; gap/alias/order | None; fail |
| Foreign segment copied to expected filename | Usually by 128-bit store identity; identical/forged ID is not excluded | None; fail on mismatch; no authenticity promise |
| Unrelated file / malformed `.tay` / symlink / hardlink | Unrelated accepted only per §11; malformed/link is explicit discovery anomaly | Ignore unrelated ordinary entry; otherwise fail |
| Stale short staged file / oversized staged file | Exact name/size checked; never a committed record | Ignore ordinary short stage without deletion; fail if oversized/type-invalid |
| Ordinary replacing rename after a successful absence precheck | A racing publisher may replace an acknowledged canonical file or immutable `STORE` | Atomic no-replace publication or fail; never replace history (§16) |
| Append short write, disk full, EINTR, permission loss, FD failure | Byte count/extent uncertainty; partial may remain | Poison live writer; fail on incomplete startup; no retry/truncate |
| Record checksum/length corruption before later valid record | Phase 1 header/record CRC or incomplete with untrusted tail | Fail; do not resynchronize or call incomplete repairable |
| Footer write short/disk full | Incomplete or damaged footer | Poison writer; defer repair; startup fail |
| New header write short/disk full | Only staged file may be partial | Ignore strictly valid-sized short staging file; no canonical mutation |
| Directory sync failure/lost response | Publication durability uncertain | Poison; on restart revalidate/resync if canonical intact; no previous next-record ack |
| Two BEAMs open same data_dir | Nonblocking helper flock refuses second | Second fails busy; first retains ownership |
| Lock helper crash | FD closes, lock releases; IPC stops mutations | BEAM writer poisoned; startup must regain lock and revalidate |
| Clean last active-record suffix disappears | No physical evidence at remaining EOF | Cannot detect or repair from surviving bytes; enforce sync contract |
| Valid footer/whole log copied with new matching CRCs | CRCs not authentication | May pass physical checks; out of accidental fault model |

For correlated corruption of multiple fields and matching CRCs, none of the
single-bit guarantees extends to arbitrary adversarial changes. The capacity
to *detect* missing data is not capacity to reconstruct it. Phase 2's
safe automatic actions are limited to **creation** after a verified sealed
high and proved genesis completion, never repair of an existing record area.

## 27. Separate adversarial acknowledged-data-loss review

This review concerns **returned `:sync` successes**, not just physically valid
CRC frames. A returned `:write` result carries weaker, explicit promises (§16).

| Incorrect implementation / crash | How acknowledged data disappears or is ignored | Mandatory prevention and residual limit |
| --- | --- | --- |
| Acknowledge after `file.write`/raw OS write but before file sync | OS/power crash loses a clean final record while remaining prefix validates | `:sync` ACK after complete exact write + successful file fsync; `:write` must disclose weaker contract |
| Acknowledge first record in newly created segment after syncing **file only** | Power failure drops directory entry; previous sealed high looks like ordinary post-seal rotation crash | Sync the `segments/` directory **before any append ACK** in new canonical; largest rotation-specific loss risk |
| Fail to sync creation of `segments/`, `data_dir`, or `STORE` | Entire segment path/identity can disappear despite syncing record contents | Sync each new directory's parent and both marker and first file names before first ACK |
| Silently treat a previously existing empty directory with missing `STORE` as virgin | Total erasure of marker and segments could become a new store instead of surfacing as loss | Auto-create only a newly created directory; require explicit bootstrap intent for pre-existing emptiness (§12) |
| Create next canonical directly, append header/record while header incomplete | Crash leaves zero/partial canonical; a later repair might delete acknowledged record | Header-only temp, file sync, rename, dir sync; never append to temp; fail on malformed canonical |
| Precheck for existing destination then use ordinary replacing rename | A competing creator may publish a canonical file/`STORE` after precheck; replacement can destroy already acknowledged history | Atomic no-replace rename for both paths; fail closed when filesystem lacks it |
| Begin next append before old footer sync or after old footer failure | Sealed old bytes may lose integrity/history while newer file survives | Full footer verification and old file sync first; poison on any uncertain old state |
| Reuse a candidate sequence after a partial or uncertain write | Two different logical events share an on-disk sequence or a gap masks one | Stop writer and revalidate on restart; only physical frames consume slots; never overwrite unresolved tail |
| Assume an interrupted/failed write wrote zero, or count a short write as complete | ACK for partial bytes and later segment rollover hides a missing event | Offset-pinned exact length/extent validation, no automatic retry/ACK on error |
| Treat lost helper reply or sync timeout as a definite failure and retry blindly | First operation may be durable; second insert doubles effects | Return uncertain, no automatic retry; Event/insertion RFC must define idempotency/reconciliation |
| Lose cross-BEAM ownership when helper dies but BEAM retains writable FD | Two writers mutate same active inode, corrupt or overwrite acknowledged history | Native helper holds lock **and all writable FDs**; Port loss prevents BEAM writes and poisons it |
| Scan forward to a later magic after incomplete/invalid frame | Corrupt B length or a staged footer causes later acknowledged C to be dropped | Stop at exact boundary; header CRC first; no resynchronization/truncation |
| Skip unknown semantic event or publish checkpoint after physical `:ok` | A cancelled/completed job can become runnable; later replay omitted | Event gate after continuity, before projection; no applied checkpoint on mere physical success |
| Accept highest sealed after entire last active file disappeared | Prior footer is valid and absence of later file is indistinguishable from crash before its creation | Directory-sync-before-ACK prevents this in supported `:sync` model; no on-disk proof if device lies |
| Lower rotation threshold/decoder budget after restart | Valid historical record misclassified oversized/incomplete and discarded | 1 GiB/16 MiB physical limits remain fixed; budgets yield resource error without repair |

The most serious *actionable* new risk is the **missing directory fsync between
canonical publication and first acknowledgement in that file**: after power
loss the whole acknowledged segment could vanish, yet the previous highest
sealed file would look like a legitimate interrupted rotation. Neither an
individual Record CRC, a segment CRC in the vanished file, nor the immutable
marker could reveal the missing active successor. The protocol prevents this
only under the stated supported filesystem/device sync guarantees. A simpler
clean loss of the final acknowledged active record has the same information
limit (§24), and `:sync` relies on successful file sync to rule it out.

## 28. Compatibility and migration boundaries

The **44-byte header, 64-byte footer, 28-byte marker, 20-digit canonical
filename, uint64 ID/sequence, store identity meaning, 1 GiB hard maximum,
checksum algorithms/coverage, reserved-byte rules, and permitted active/sealed
topology** become stable v1 contracts on approval. The approved Phase 1 Record
bytes embedded inside are unchanged. A future reader must continue validating
these files exactly or use an explicitly reviewed new version/migration; an
older reader must stop on unsupported segment/marker version without rewriting
history. A new header/footer field, CRC input, hard format bound, changed footer
placement, or relaxation of reserved bytes requires a new reviewed segment
version. Changing Store marker layout similarly requires a new STORE_VERSION
and migration protocol. A future record-framing version cannot silently use
this v1 record area (§2).

`rotation_target_bytes`, requested durability policy, reader resource budget,
queue configuration, `%Tay.Job{}` layout, modules/atoms, and actual Event
capabilities are **not on disk** in this container and must not make an old
physically valid segment unreadable. An Event schema unsupported by an older
application remains a semantic replay stop after all physical checks; it is not
physical corruption or permission to skip. From Phase 1, a different
application process may independently read a valid Record blob, but only the
correct store and full segment topology can make it valid *segment history*.
The candidate 32-byte header/16-digit name has never been implemented; this
proposal does not require an on-disk migration of deployed Tay segments.

## 29. Proposed golden compatibility fixtures

On approval and implementation, independently generate and commit permanent
literal `.tay` files (and `STORE`) under a versioned fixture directory. This
RFC creates **no `.tay` files** and uses no production Segment/Writer/Reader
encoder. Use Phase 1 fixed F01/F02/F18 bytes for Record bodies, and an
explicit **test-only** STORE_ID `00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff`;
it is not a production default UUID or production event allocation. The
following proposed bytes were calculated *in memory* using a separate reflected
CRC32C implementation and cross-checked against the Phase 1 test-only
**normal-polynomial left-shifting** reference oracle (not `Tay.Storage.Record`):

```text
STORE, 28 bytes (CRC = AE533C93):
54 41 59 49 01 00 00 00 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff ae 53 3c 93

Header, ID=1 FIRST=1, 44 bytes (CRC = 3D7C68B9):
54 41 59 53 01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 3d 7c 68 b9

Footer, ID=1 FIRST=1 LAST=1 COUNT=1, 64 bytes:
54 41 59 46 01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff cb 67 4b b0 5c 6f d9 b9

Footer, ID=1 FIRST=1 LAST=3 COUNT=3, 64 bytes:
54 41 59 46 01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 03 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 8e 14 5c fc 54 dc 2a e8

Header, ID=2 FIRST=4, 44 bytes (CRC = 6ABAEFCC):
54 41 59 53 01 00 00 00 00 00 00 00 00 00 00 02 00 00 00 00 00 00 00 04 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 6a ba ef cc
```

The one-record **segment** CRC is `CB674BB0` over `(44-byte header ||
F01's 28 bytes)`; the three-record segment CRC is `8E145CFC` over
`(header || F01 || F02 || F18)`. The one-record sealed file is exactly
`44 + 28 + 64 = 136` bytes. The three-record sealed file is
`44 + 28 + 37 + 28 + 64 = 201` bytes. The independently checked footer CRCs
are `5C6FD9B9` and `54DC2AE8`, respectively. Do not generate the expected
fixtures from production encode functions or rewrite negative fixtures until
they pass; use independent construction and pin literal bytes.

| Proposed fixture | Exact composition / alteration | Expected physical result |
| --- | --- | --- |
| S01 | Header(ID1,FIRST1), EOF; plus matching STORE | Valid empty active |
| S02 | Header(ID1,FIRST1) + Record F01; matching STORE | Valid active one record; EOF at Record boundary |
| S03 | Header(ID1,FIRST1) + F01 + F02 + F18 | Valid active three records, sequences 1–3 |
| S04 | Header(ID1,FIRST1) + F01 + above COUNT1 footer | Minimal valid sealed, exact 136 bytes |
| S05 | Header(ID1,FIRST1) + F01 + F02 + F18 + above COUNT3 footer | Valid multi-record sealed, exact 201 bytes |
| S06 | S01 with a single bit flipped in stored header CRC | Corrupt header CRC; do not infer an empty store |
| S07 | S01 bytes under filename for ID2, with valid STORE | Internal/filename ID mismatch |
| S08 | S04 with final footer CRC byte XOR `01` | Footer CRC corrupt; never fall back to active |
| S09 | S04 with segment CRC field `CB674BB1`, **recomputed footer CRC `AE045ABA`** | Footer valid, segment CRC corrupt |
| S10 | S04 truncated after the first 1, 3, 4, 36, or 63 footer bytes | Highest incomplete/ambiguous footer; earlier-segment failure; no repair permission |
| S11 | Valid header FIRST2 with otherwise sequence-1 F01; independent CRCs recomputed | Sequence mismatch even if individual Record CRC is valid |
| S12 | S04 + arbitrary trailing bytes, or S04 + duplicate footer | Corrupt unexpected bytes/duplicate footer |
| S13 | S04 as ID1 and a standalone ID2 FIRST4 header from above | Each file physically valid; store history **fails continuity** because successor FIRST must equal 2; include a separate corrected FIRST2 variant |
| S14 | Explicit all-zero STORE_ID header/marker with independently recomputed CRCs | Invalid structural identity, not a zero-ID fallback |
| S15 | S05 as sealed ID1 plus the pinned ID2/FIRST4 empty-active header | Valid two-segment store history; successor anchor equals preceding LAST+1 |

S13 deliberately pairs a byte-correct header with an inconsistent previous
footer to prove multi-file continuity; the independently pinned ID2/FIRST4
header is useful with S05, which ends at 3. The actual valid one-record
successor must be separately pinned as ID2/FIRST2; never quietly reuse the
wrong header just because its CRC validates. Future Phase 2 tests must also
include ID boundary/overflow, 1 GiB length rejection, 16 MiB records, lower
rotation targets after restart, read limits, all footer-prefix lengths,
single-bit fields, arbitrary payload-embedded `TAYF`, and fresh-VM replay.

## 30. Required lifecycle/fault-injection tests on implementation

The Phase 2 test matrix is not complete with only codec round trips. Under
the supported OS/storage target, simulate/kill the writer/native helper after
each R-state of §20, including during old footer and temp-header writes, after
old file sync, before/after rename, and before/after directory sync. Assert the
exact visible file set, next ID and sequence, valid/error classification, and
absence of any unacknowledged-to-acknowledged upgrade. In every failed case
snapshot canonical file bytes beforehand; assert no existing history was
truncated or deleted. Reopen clean multi-segment histories, highest-sealed
histories, and initialized empty-active histories.
Test absent-marker pre-existing directories both empty and containing only
recognized staging: no silent new identity without one-time bootstrap intent;
test the narrowly allowed single canonical ID-1 bare header completion.

Use a second **independent BEAM process** on the same local `data_dir` to prove
the OS lock prevents concurrent writers, including after writer/helper kill;
check stale persistent lock-file inode and verify that a PID-file imitation
cannot grant ownership. Test competing creation, reused/symlink lock paths,
fd loss, short positive writes, interrupted writes, disk full during record,
footer, and temp header, sync/directory-sync errors, and unknown helper replies.
Assert that the old canonical writable FD is closed after R2, the temp's
writable FD after R4, and that the next canonical is opened writable only at
R7; inject an error on each close and require a poisoned writer.
Inject a destination created **between** the absence precheck and publication;
assert the atomic no-replace operation fails without changing that destination
for both the segment and `STORE`. Reject a filesystem without this syscall.
Inject an intact canonical file after a failed dirsync and a missing canonical
file after a crash before dirsync: no next-record success may have been sent.
Tests for directory sync are required; merely mocking `file:sync` on the data
file does not establish the OS crash contract.

Use bounded streaming/reopen tests for 1 GiB-valid geometry without necessarily
committing huge fixtures. Enforce that a sealed segment, earlier active, odd
`.tay` name, symlink/alias, zero file, missing first ID, missing intermediate
ID, foreign STORE_ID, footer-like payload, resource-limit error, unknown
Record/Event semantics, or any corrupt remainder cannot be silently skipped.
Actual Phase 3 authorized repair/recovery tests remain **deferred** and must not
be pretended to pass by a read-only Segment/Reader unit test. Platform capability
tests must fail closed for unsupported directory sync or `flock`; macOS
power-loss `:sync` requires its own separately approved evidence/adapter.

## 31. Decisions assigned to later work and implementation gate

**Payload/Event and insertion RFC:** real job-event IDs/schema/serialization,
durable application idempotency/correlation identity and unknown-commit retries,
Event-before-Projection validation, and applied-state/checkpoint readiness.
Segment/Record framing is not event admission.

**Phase 3 Recovery RFC:** exact evidence/authorization for any tail repair or
torn footer treatment, sealed-versus-active damage, sync/error evidence, whether
an unacknowledged but complete frame can be replayed, snapshot anchor
integration, and no publication of partial recovery. Phase 2 intentionally
fails closed for incomplete canonical history; it does not solve Phase 3.

**Future snapshot/manifest RFC:** independently durable/high-water coverage,
manifest replacement and directory sync, snapshot/ID anchoring, removal of old
segments, and compaction. An immutable `STORE` is **not** a mutable manifest.
Even a future manifest cannot make clean vanished bytes reconstructable.

**Before Phase 2 code**, approval must cover both proposed layouts **and** the
mandatory native helper/lock/sync boundary, Linux-only verified strict
durability scope, immutable marker, atomic no-replace publication, production
`data_dir` storage-location semantics deferred from Phase 0, and fail-closed
states. Specific blocking questions for review are: **Do we accept a native
Port helper as the sole holder of both the OS directory lock and every writable
segment FD, with `:sync` unsupported on unverified macOS filesystems? What is
the production `data_dir` location/ownership contract?** If the helper boundary
is rejected, the rotation/durability protocol needs revision before
implementation. The developer must demonstrate
the chosen local filesystem's file + directory sync behavior and crash/fault
testing; neither a convenient OTP API name nor a successful `:write` return
discharges that obligation. This RFC makes no native/production code, segment
files, locks, durability configuration, or Phase 3 changes.

## 32. Final recommendation

The following two verdicts recommend approving the exact *proposed* v1 bytes
and states above, conditional on explicitly reviewing the implementation
gates in §31; they do not authorize Phase 2 code by themselves.

APPROVE SEGMENT FORMAT

APPROVE ROTATION PROTOCOL
