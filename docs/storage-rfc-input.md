# User-supplied storage candidates for future RFC review

Status: design input accepted for preservation during Phase 0 only. This file
records the user's supplied candidates; it is not a Phase 1/2 RFC, a completed
review, or an implemented compatibility contract. No Phase 1 or Phase 2 code is
authorized by recording these candidates.

Read alongside [TAY_PLAN.md](../TAY_PLAN.md) and the
[accepted adversarial review](phase-1-review-input.md). All candidate layouts and
protocols below still require their respective RFC reviews before code is written.

## Record framing candidate for Phase 1

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `MAGIC = "TAY\x00"` |
| 4 | 1 | `FORMAT_VERSION` |
| 5 | 1 | `RECORD_TYPE` |
| 6 | 1 | `FLAGS` |
| 7 | 1 | `PAYLOAD_SCHEMA_VERSION` |
| 8 | 8 | `SEQUENCE` |
| 16 | 4 | `PAYLOAD_LENGTH` |
| 20 | 4 | `HEADER_CRC32C` |
| 24 | N | `PAYLOAD` |
| 24+N | 4 | `RECORD_CRC32C` |

The candidate has a fixed 24-byte record header and total record size of
`28 + payload length`. Use big-endian integer encoding unless a later RFC
demonstrates a reason to change it. This remains a candidate pending Phase 1 RFC
review, not an implemented compatibility contract.

## Two record-level integrity layers

`HEADER_CRC32C` allows validation of framing metadata before trusting
`PAYLOAD_LENGTH`. It must protect every header interpretation field preceding
the checksum: magic, format version, record type, flags, payload schema version,
sequence, and payload length. A corrupted length must become a corrupt header,
not an apparently incomplete payload.

`RECORD_CRC32C` validates the full logical record. The candidate coverage is the
protected header fields plus the payload, excluding checksum fields themselves
unless the RFC explicitly chooses another canonical calculation. The Phase 1
RFC must specify the exact checksum input bytes.

## Parser classification and recovery authorization

`Tay.Storage.Record` classifies bytes. `Tay.Storage.Recovery` decides whether a
recovery action is legal. Possible codec outcomes supplied for later review are:

```elixir
{:ok, record, rest}
{:incomplete, :header}
{:incomplete, :payload, metadata}
{:incomplete, :checksum, metadata}
{:error, :invalid_magic}
{:error, :header_checksum}
{:error, :record_checksum}
{:error, {:unsupported_format, version}}
{:error, {:unsupported_type, type}}
```

Exact return types will be designed later. An `incomplete` result does not mean
safe to truncate. The record codec must never truncate files. Repair
authorization belongs to Phase 3 and depends on segment state and the documented
failure model. Decoder stream-consumption semantics must be explicit.

## Sequence number

The candidate `SEQUENCE` is an unsigned 64-bit monotonic log sequence number.
It supports detection of missing records when later records exist, detection of
duplicate/out-of-order records, ordering across segments, future snapshot
positions, and a stable logical log coordinate.

Do not add `previous_sequence`: continuity is checked against the prior record.

## Unknown semantics and flags

Recovery must stop for unsupported framing versions, unsupported record types,
unsupported payload schemas needed for semantic replay, and unknown mandatory
flags. Storage must remain untouched on unsupported semantics. Unknown semantic
records must not be silently skipped and thereby resurrect cancelled/completed
jobs in older readers.

The candidate reserves one byte for flags, initially all zero. The RFC must
define understood bits and whether any future bits may safely be ignored.
Unknown mandatory flags must never be ignored.

## Payload boundaries

No ETF, CBOR, MessagePack, Protobuf, or custom durable payload format is approved.
For Phase 1 framing, the supplied direction is an opaque `binary()` payload.
The conceptual responsibilities are:

| Layer | Responsibility |
| --- | --- |
| Record codec | Structural byte validity |
| Event codec | Payload meaning/schema |
| Projection | Job state transition |

Canonical persisted serialization requires a separate RFC before the first real
durable job event is committed as a stable format. ETF is specifically not
approved as the canonical durable encoding. Persisted payloads must not depend
on the current `%Tay.Job{}` layout or the presence of runtime atoms/modules.

## Limits and fixtures

The future design must distinguish the format hard maximum record size from a
configurable insertion limit. A valid historical record must remain readable
when a later deployment lowers its insertion limit. Resource/decode limits are
a third concern and must not authorize truncation.

Once the Phase 1 format is approved, create fixed v1 byte fixtures immediately.
Do not wait until Phase 10. Round-trip tests alone allow the encoder and decoder
to drift together.

## Segment envelope direction for the Phase 2 RFC

Record framing alone is insufficient. The supplied segment direction is:

```text
SEGMENT HEADER
RECORD
RECORD
...
SEGMENT FOOTER   # sealed segments only
```

A candidate fixed 32-byte segment header is:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `MAGIC = "TAYS"` |
| 4 | 1 | `VERSION` |
| 5 | 1 | `FLAGS` |
| 6 | 2 | `RESERVED` |
| 8 | 8 | `SEGMENT_ID` |
| 16 | 8 | `FIRST_SEQUENCE` |
| 24 | 4 | `HEADER_CRC32C` |
| 28 | 4 | `RESERVED` |

The internal segment ID permits checking the filename against file contents.
The first sequence permits continuity checks between segments. This is an RFC
candidate, not a final format.

Sealed segments should have footers; active segments should not require them.
The proposed footer concepts are `MAGIC = "TAYF"`, `VERSION`, `SEGMENT_ID`,
`FIRST_SEQUENCE`, `LAST_SEQUENCE`, `RECORD_COUNT`, `SEGMENT_CRC32C`, and
`FOOTER_CRC32C`. Its exact byte layout is not approved.

The intended integrity levels are header CRC for framing metadata, record CRC
for individual records, and segment CRC plus sealed footer for sealed history.

## Active/sealed direction before a manifest exists

The proposed rule treats the highest segment ID as an active candidate. Earlier
segment IDs must be sealed with valid footers. If the highest segment already
has a valid sealed footer after a rotation crash, recovery may create the next
active segment according to the future Phase 2/3 state machine.

This rule must be formally reviewed before implementation.

## Rotation durability direction

Phase 2 must separately define file/directory synchronization and segment-creation
durability. The supplied candidate rotation sequence is:

1. Stop appending to the old active segment.
2. Append its sealed footer.
3. Fsync the old segment.
4. Create the next segment.
5. Write its segment header.
6. Fsync the new segment.
7. Fsync the directory where required.
8. Make the new segment active.
9. Resume appends.

Every crash point must be analyzed in the future RFC. This protocol must not be
implemented until that RFC has been reviewed.

## Limit of framing

Framing cannot prove that a fully acknowledged final active-log record existed
if all its bytes later disappear cleanly and no later sequence remains.
Acknowledged-data durability depends on correct write ordering, sync semantics,
and filesystem/storage guarantees. Framing detects corruption that remains
observable; it cannot reconstruct bytes that no longer exist.

Phase 0 ends with preservation of this input. Beginning the Phase 1 RFC requires
an explicit instruction.
