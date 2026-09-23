# Storage and recovery contract

Tay v0.9.1 has one authoritative append-only store per Engine. Runtime ETS
indexes are disposable projections, not a second source of truth. Record v1,
STORE v1, Segment v1, and Event v1 are frozen compatibility contracts: changing
their bytes or meanings requires an explicitly versioned migration. The
committed binary fixtures under `test/fixtures/storage/` and the Event literals
and `SHA256SUMS` under `test/fixtures/events/v1/` are independent compatibility
anchors. Tests use those fixtures directly and never parse this page.

## Physical formats

All multibyte fields are unsigned big-endian. A Record v1 has a 24-byte header:
`TAY\0` magic (4), format version (1), type (1), flags (1), payload schema (1),
sequence (8), payload length (4), and header CRC32C (4). It is followed by the
opaque payload and a four-byte record CRC32C. The header CRC covers header
bytes `0..19`; the record CRC covers those same bytes followed by the payload.
The hard payload maximum is 16,777,216 bytes, so complete record size is
`28 + payload_length`. Type `1..254` and schema `1..255` are physically
assignable even when their Event meanings are unknown. Zero or 255 type, zero
schema, nonzero flags, broken CRC, and invalid lengths are refused as specified
by the v1 codec. Physical decoding never authorizes semantic replay or repair.

`data_dir/STORE` is an immutable 28-byte genesis marker: `TAYI`, version 1,
zero flags/reserved bytes, a random nonzero 16-byte STORE_ID, and CRC32C over
the first 24 bytes. It is neither a manifest nor a tail checkpoint. All segment
headers and footers must carry that same STORE_ID; a missing or replaced marker
is never regenerated during recovery.

Canonical segments live under `data_dir/segments/` and are named exactly 20
zero-padded decimal ID digits plus `.tay`, starting at ID 1 without gaps. A
segment has a 44-byte `TAYS` v1 header containing ID, first sequence,
STORE_ID, and CRC32C. A sealed segment ends with a 64-byte `TAYF` v1 footer
containing matching identity/coordinates, last sequence, record count, segment
CRC32C, and footer CRC32C. An active empty segment is exactly its 44-byte
header; an empty sealed segment is invalid. Records and segment IDs advance
contiguously. The physical segment size bound is 1 GiB; the rotation target is
an operational setting, not a change to the format.

## Event and recovery boundary

Event v1 understands exactly type/schema pairs `(1,1)` through `(6,1)`:
inserted, available, started, finished, cancelled, and retried. Payloads have
canonical bounded value encoding and immutable schema-1 field meanings.
Physical readability of a different pair does not imply support. Worker and
queue identities are inert UTF-8 keys; persisted bytes never select Elixir
modules or create atoms. A future event field needs a new explicit schema and
literal fixtures, not an optional field in schema 1.

Recovery acquires the existing store and lock, validates every canonical byte
and sequence, then replays every complete understood event into a private
candidate. Unknown semantics, invalid transitions, missing history, corruption,
or an incomplete tail stop the attempt without publishing a partial candidate
or mutating the source. A recovered writer may activate only while retaining
the same ownership session and after full revalidation. There is no scan-ahead,
automatic torn-tail truncation, stage deletion, or writable-prefix salvage.
Inspection and copy catalogs do not grant activation authority.

Resource budgets for decoding, candidate state, directory traversal, and
history admission are operational limits. Lowering them can refuse an otherwise
valid history but cannot redefine physical or semantic validity. A larger
budget permits a new complete inspection; it never makes corrupt bytes valid.
No retained job or segment is automatically evicted, and individual log files
must not be removed to reclaim capacity.
