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

New nonempty checkpoints also publish `RECOVERY` beside `MANIFEST` and
`segments/`. It is an immutable index of base job-snapshot locations, not a
second job journal. Tail changes remain authoritative over those snapshots.
Empty checkpoints omit the index. Earlier checkpoints without it remain valid;
readers which do not recognize the extended manifest refuse new checkpoints.

The optional manifest field `recovery_index` contains `bytes` (the exact file
length), `root` for jobs and `auxiliary` for schedule/result records (byte strings
encoded by `DiskIndex.encode_root/1`). Earlier job-only descriptors remain readable. The root
envelope is a canonical Value map with `version: 1` and an optional `root`
reference. Each reference contains `offset`, `bytes`, SHA-256 `digest`, binary
`first`/`last` keys, entry `count`, and tree `height`. A reference's digest covers
the exact encoded page. Root metadata is covered by the manifest digest in
`CURRENT`. All map keys on disk are strings; binary keys/digests use Value's
byte carrier.

Pages are canonical Value maps with `version: 1` and either `leaf` entries or
`children` references. Leaf entries are ordered binary-key/value pairs; keys
are strictly increasing. Children have disjoint ordered key ranges, matching
counts and heights, and point only to earlier bytes in the same file.
Pages have at most 64 entries/references. This is internal page structure,
not a configurable job count or recovery quota.

Job keys are raw 16-byte IDs. A location value contains `segment`, `offset`,
`bytes` (complete Record size), `sequence` (physical snapshot sequence) and
`digest` (SHA-256 of the snapshot payload). Addressed reads verify native file
identity, bounds, Record CRC, type/schema `(7,1)`, sequence, payload digest and
decoded job ID. Terminal locations also contain an authenticated `summary`: a
snapshot with empty arguments, the original encoded definition length and its
terminal memory charge. The auxiliary tree uses big-endian 64-bit physical
sequences as keys and authenticates the locations of schedule/result records.
Full semantic replay independently reconstructs job locations and summaries
from parsed records and compares them with the index before candidate publication. Missing, orphaned, truncated or mismatched indexes
refuse recovery without repair.

The native owner appends and syncs the index before manifest publication and
the atomic CURRENT switch. Index bytes are included in candidate-space
admission and publication measurements; like MANIFEST, they are metadata rather
than journal segment bytes. Activation syncs the index, cold copy includes it,
and predecessor reclamation unlinks and directory-syncs it before removing
MANIFEST. Engine startup reads index metadata, validates base headers/footers,
loads active snapshots and auxiliary records by authenticated location, then
replays the tail. Cold terminal arguments are read only on job lookup or when a
tail mutation needs that job. Missing/corrupt cold record bodies are detected at
that read and fail the Engine closed; they never become `not_found`. Inspection
and publication retain full physical/semantic replay for an archive-wide check.
Older indexes and checkpoints without an index use full replay.

Startup still traverses terminal metadata to rebuild history ordering/counts;
it is proportional to retained IDs, active bodies, result bodies and tail size.
It does not yet provide startup independent of archive ID count. Results remain
in the Engine memory budget. These limits are distinct from lazy argument loading.

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
Unreleased builds add `(14,2)` for atomic successful external completion. Its
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
