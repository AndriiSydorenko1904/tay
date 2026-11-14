# Storage and recovery contract

This is the persistent-format reference for Tay 2.0. For setup, configuration,
backup and restore, start with [operations](operations.md). For supported
platforms and upgrade restrictions, see [compatibility](compatibility.md).

Tay has one authoritative append-only Store-v2 generation per Engine. Runtime ETS
indexes and the disk-backed terminal inspection index are disposable
projections, not a second source of truth. Record v1, Segment v1, and Event v1
are frozen framing and semantic contracts inside Store v2: changing their bytes
or meanings requires an explicitly versioned migration. The
committed binary fixtures under `test/fixtures/storage/` and the Event literals
and `SHA256SUMS` under `test/fixtures/events/v1/` are independent compatibility
anchors. Tests use those fixtures directly and never parse this page.

## Physical formats

All multibyte fields are unsigned big-endian. A Record v1 has a 24-byte header:

| Byte offset | Field | Size in bytes |
| --- | --- | ---: |
| 0 | Magic `TAY\0` | 4 |
| 4 | Format version | 1 |
| 5 | Record type | 1 |
| 6 | Flags | 1 |
| 7 | Payload schema | 1 |
| 8 | Sequence | 8 |
| 16 | Payload length | 4 |
| 20 | Header CRC32C | 4 |

The header is followed by the opaque payload and a four-byte record CRC32C.
The header CRC covers header
bytes `0..19`; the record CRC covers those same bytes followed by the payload.
The hard payload maximum is 16,777,216 bytes, so complete record size is
`28 + payload_length`. Type `1..254` and schema `1..255` are physically
assignable even when their Event meanings are unknown. Zero or 255 type, zero
schema, nonzero flags, broken CRC, and invalid lengths are refused as specified
by the v1 codec. Physical decoding never authorizes semantic replay or repair.

New initialization publishes a `STORE-V2` authority marker, an empty immutable
generation, and an atomic `CURRENT` pointer before reporting success. It never
creates `data_dir/STORE` or `data_dir/segments`. The STORE_ID is carried by the
V2 marker, manifest, CURRENT pointer, and every segment header/footer.

Store-v1 roots with `data_dir/STORE` and a root `segments` directory are not
supported by Tay 1.5 and later, including 1.8. They must be opened and migrated
by Tay 1.4.x before upgrading. Current versions never create, import, adopt, or
repair Store v1.

Store-v2 canonical segments live below the CURRENT epoch's `segments/`
directory and are named exactly 20
zero-padded decimal ID digits plus `.tay`, starting at ID 1 without gaps. A
segment has a 44-byte `TAYS` v1 header containing ID, first sequence,
STORE_ID, and CRC32C. A sealed segment ends with a 64-byte `TAYF` v1 footer
containing matching identity/coordinates, last sequence, record count, segment
CRC32C, and footer CRC32C. An active empty segment is exactly its 44-byte
header; an empty sealed segment is invalid. Records and segment IDs advance
contiguously. The physical segment size bound is 1 GB; the rotation target is
chosen internally by the storage engine, not a public setting.

## Checkpoint location index (2.0)

Online checkpoints publish immutable `RECOVERY` metadata beside `MANIFEST` and
`segments/`. Tail changes remain authoritative over snapshots. Earlier
checkpoints without an index and the preceding job-only/job-plus-auxiliary
index descriptors remain readable through their existing replay paths.

The current descriptor contains `format: 3`, `bytes` (the exact current index
file length), and seven roots encoded by `DiskIndex.encode_root/1`. Format 2,
with its original five roots, remains readable and is migrated by the next
checkpoint:

| Root | Key | Value |
| --- | --- | --- |
| `root` | raw 16-byte job ID | snapshot pointer, including terminal summary |
| `work` | raw 16-byte active job ID | same snapshot pointer |
| `expiry` | unsigned big-endian terminal time followed by job ID | same terminal pointer |
| `schedules` | schedule ID | canonical `(13,2)` record pointer |
| `results` | raw job ID | canonical `(10,2)` record pointer |
| `history` | inverted insertion time followed by job ID | terminal summary pointer |
| `stats` | `summary` | terminal state/facet, charge and retention-bucket aggregates |

Even an empty current checkpoint has a 64-byte index header: `TAYI`, version
byte `3`, and 59 zero bytes. Null roots use the existing version-1 root envelope.
The old descriptor is `{bytes, root}` or `{bytes, root, auxiliary}` and has no
header; its auxiliary tree uses physical sequence keys.

Every page reference authenticates offset, encoded length, SHA-256 digest,
first/last key, count and height. Format-2/3 references additionally identify the
16-byte source epoch and summarize reachable files and live record bytes.
File keys are `epoch[16] || scope[1] || segment_id[u64] || sealed_bytes[u64]`;
scope zero names that epoch's `RECOVERY` with both integers zero, and scope one
names an immutable segment. Summaries are sorted, unique, checked against the
page contents, and covered by each parent's digest. The manifest digest in
CURRENT authenticates all roots. On-disk maps use string keys and Value byte
carriers for binary fields.

Pages contain at most 64 ordered leaf entries or disjoint child references.
Children have matching counts and strictly decreasing height. Same-file child
references precede their parent; cross-epoch children identify an immutable
published file. Batched updates append changed paths and retain unchanged
references. Immutable pages are never edited in place.

Record pointers contain source `epoch`, `segment`, `offset`, complete Record
`bytes`, physical `sequence`, SHA-256 payload `digest`, sealed `segment_bytes`
and whole-file `segment_digest`. Terminal pointers include an authenticated
summary snapshot with empty arguments, original definition length and memory
charge. Addressed reads verify pinned file identity, extent, Record CRC,
type/schema, sequence, payload digest and decoded identity. Missing/corrupt
addressed bodies fail closed and never become `not_found`.

The first checkpoint of an older format builds all roots; publication still
uses the existing directory-sync and atomic CURRENT ordering. Later builders
load the work root, schedules and frozen new tail, hydrate only affected archive
records, and update job/work/expiry/result paths. The expiry tree finds elapsed
retention without scanning retained IDs. A bounded cleaner can additionally
move live records from sparse segments. New pages and touched records are
independently read back before publication; inherited references retain their
published authentication. Full inspection and cold backup scrub reachable
segments and verify the root/work/expiry partition and auxiliary identities.

Native readers pin the archive ancestors and revalidate them on each read.
Reclamation derives reachability from all descriptor roots, checks exact CURRENT
before each batch, refuses pinned/current/candidate epochs, and syncs deletion
directories. Referenced older epoch files survive publication. Background GC
resumes on startup. Cold backup/restore copies every reachable epoch file,
retaining the relative paths and checksummed catalog; an old epoch MANIFEST is
not needed to resolve an authenticated pointer.

When more than 32 older index epochs remain reachable, checkpoint construction
also evacuates pages from one metadata file. The shared read budget is 64 MiB
across all roots; an individual page and rewritten ancestor paths may
extend the final portion. Unvisited subtrees retain their authenticated old
references. Only after the last reference disappears may GC remove that
`RECOVERY` file. Argument/result segments are not read during page evacuation.

Startup loads the `work` root plus the bounded tail. It does not traverse
terminal IDs, rebuild terminal DETS, or load result bodies. Terminal lookups and
Dashboard pages use authenticated `root`/`history` paths; state/facet counts and
compaction estimates initialize from the `stats` aggregate. Result payloads are
read by authenticated record location only when requested. Older binaries that
do not understand format 3 refuse it; downgrade requires a pre-upgrade backup.

## Event and recovery boundary

The frozen Event-v1 subset understands exactly type/schema pairs `(1,1)` through `(6,1)`:
inserted, available, started, finished, cancelled, and retried. Payloads have
canonical bounded value encoding and immutable schema-1 field meanings.
Event v2 additionally assigns schema-2 pairs `(7,2)` through `(10,2)` to
schedule registration, schedule advancement, schedule cancellation, and
successful-result recording. Tay 1.8.0-rc3 adds `(11,2)` for delivery/skip advancement
with a persisted `active_job_id`, `(12,2)` for historical schedule checkpoints,
and `(13,2)` for new registration/state/checkpoints with the complete
`active_job_ids` set and `membership_complete` flag.
Tay 2.0 adds `(14,2)` for atomic successful external completion. Its
exact fields are `at`, `execution_token`, `expected_revision`, `job_id` (bytes),
and `result`. It requires the matching executing job and token, advances the
logical job revision once, and stores the result at that new revision in the
same physical record. Compaction retains the completed snapshot and its existing
`(10,2)` result checkpoint. Binaries through Tay 1.8.1 cannot read `(14,2)`;
downgrade after writing it requires a pre-upgrade backup.

The checkpoint records definition, original logical revision, registration time,
next/last due times, cancellation time and occurrence membership. It preserves schedule
CAS identity across compaction, independently of physical record coordinates.
Earlier type/schema pairs and Record framing remain byte-for-byte unchanged.
Schema 2 keeps logical Event types 7 and 8
unambiguous from Store-v2's schema-1 snapshot and mutation record types.
The engine emits and projects these pairs during live operation, recovery, and
Store-v2 compaction. Store-v2 canonical bases retain schedules and the results
whose completed jobs survive terminal-retention filtering.
Physical readability of a different pair does not imply support. Worker and
queue identities are inert UTF-8 keys; persisted bytes never select Elixir
modules or create atoms. A future event field needs a new explicit schema and
literal fixtures, not an optional field in schema 1.

Recovery acquires the existing store and lock and builds a private candidate.
With an extended index it validates authority, metadata, active/auxiliary records
and the entire tail; cold terminal bodies are checked on addressed read. Without
that index, recovery validates every canonical byte and replays the full snapshot
and ordered tail. Unknown semantics, invalid transitions, missing required
history, corruption in inspected data, or an incomplete tail stop the attempt
without publishing a partial candidate or mutating the source. Activation retains
the same ownership session and revalidates the same view using its original
recovery mode. There is no writable-prefix salvage, automatic torn-tail
truncation or corruption repair. Inspection and copy catalogs do not grant
activation authority.

Resource budgets for active candidate payload data and history admission are
operational limits. Directory inventory is streamed in bounded native protocol
pages without a total file-count quota. Lowering them can
refuse an otherwise valid active workload but cannot redefine physical or
semantic validity. A larger budget permits a new complete inspection; it never
makes corrupt bytes valid. Job counts are not capped. Terminal history is
removed only by successful time-based compaction; active jobs are never
evicted. Individual log files must not be removed to reclaim capacity.

Offline inspection and legacy recovery replay the complete retained history.
Indexed Engine recovery reads metadata, active/auxiliary data and the tail under
the configured time and state-memory budgets, with fixed format/Value checks.
Record payloads use the fixed 16 MiB format ceiling and the common Value codec
checks. Recovery has no separately configurable payload or Value budgets.

The physical record decoder exposes only `Tay.Storage.Record.decode/1`.
Its payload ceiling is fixed at 16 MiB; neither the decoder nor the segment
parser accepts a configurable decode payload limit.
