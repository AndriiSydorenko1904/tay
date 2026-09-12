# RFC: Phase 1 storage record format

Status: **approved authoritative Phase 1 implementation specification**.
Date: 2026-09-12. Scope: the pure record codec, its conformance contract, and
adversarial analysis. Implementation is limited to the pure Phase 1 codec;
segment I/O, Event serialization, continuity enforcement, and recovery remain
future work.

Inputs: [TAY_PLAN.md](../TAY_PLAN.md), the
[record/segment candidates](storage-rfc-input.md), the
[accepted adversarial review](phase-1-review-input.md), and the existing
`Tay.Application`, `Tay.Supervisor`, `Tay.Config`, `Tay.Job`, and `Tay.Worker`.
At approval, the runtime had no storage code or durable configuration to migrate.

The 24-byte physical header, CRC32C specification, sequence design, physical
validation order, 16 MiB v1 hard limit, opaque payload model, and golden-fixture
strategy are approved. This revision removes semantic registry membership from
the record codec; the relative order of all physical checks is unchanged.
MUST, MUST NOT, and SHOULD describe the approved implementation contract,
including the physical/semantic boundary revision. Approval authorizes Phase 1
only. This document defines no event serialization or filesystem repair procedure.

## 1. Exact byte layout

Offsets are zero-based from the start of one record. Ranges in prose are
inclusive; `bytes[a:b]` in expressions is half-open. All multi-byte integers,
including stored CRC results, are unsigned and big-endian. One-byte integers
have no endianness. No padding, alignment bytes, compression, or terminator is
inserted. `N` is payload length in bytes; `HARD_PAYLOAD_MAX = 16_777_216`.

| Offset | Width | Field/type | Legal v1 values | Rejection | Validation step in §12 |
| --- | --- | --- | --- | --- | --- |
| 0 | 4 | `MAGIC`, literal bytes | `54 41 59 00` | Any observed mismatching byte: corrupt magic | 1 |
| 4 | 1 | `FORMAT_VERSION`, uint8 | `1` for this decoder | `0`: invalid; `2..255`: unsupported framing | 2 |
| 5 | 1 | `RECORD_TYPE`, uint8 | Any value in `1..254`, regardless of semantic support | `0`, `255`: reserved | 6 |
| 6 | 1 | `FLAGS`, uint8 | `0` | Every nonzero value: unsupported mandatory flags | 5 |
| 7 | 1 | `PAYLOAD_SCHEMA_VERSION`, uint8 | Any value in `1..255`, regardless of semantic support | `0`: invalid | 7 |
| 8 | 8 | `SEQUENCE`, uint64 | `1..18_446_744_073_709_551_615` | `0`: invalid; stream discontinuity is checked separately | 8, §7 |
| 16 | 4 | `PAYLOAD_LENGTH`, uint32 | `0..16_777_216` | Larger values violate the format hard limit | 9 |
| 20 | 4 | `HEADER_CRC32C`, uint32 | Exactly `CRC32C(bytes[0:20])` | Mismatch: corrupt header | 4 |
| 24 | N | `PAYLOAD`, binary bytes | Any exactly N bytes, including empty/invalid UTF-8 | Fewer bytes: incomplete payload | 11 |
| 24+N | 4 | `RECORD_CRC32C`, uint32 | Exactly `CRC32C(bytes[0:20] || bytes[24:24+N])` | Missing bytes: incomplete checksum; mismatch: corrupt record | 12, 13 |

Fixed header: **24 bytes**. Fixed overhead: **28 bytes**. Complete record size:
`28 + N`. The last record byte is at offset `27 + N`; the next record, if any,
starts at `28 + N`. No field outside the table exists in v1.

Legal integer ranges describe wire values, not a license to execute unknown
events. Physical validity, supported semantics, and valid job transitions are
different checks owned by different layers (§14). Unknown semantics are not
corrupt physical records; semantic support is never an input to this codec.

## 2. Magic

Retain `"TAY\x00"`, exactly four bytes `54 41 59 00`. It is a type marker at a
known record boundary, not a globally unique identifier or an integrity proof.
Four bytes suffice for that responsibility because the header CRC protects the
fixed framing fields and the parser never searches arbitrary data for magic.
Longer magic would add overhead without solving missing data or forged records.

Compare every available magic-prefix byte. For example, `54 41` is incomplete;
`54 42` is corrupt immediately. Zero input bytes are incomplete. A complete
wrong magic, including `TAYS` or `TAYF`, is not a record.

Forward scanning/resynchronization is **never allowed** in this codec or normal
replay after an error. Magic can occur inside an opaque payload. Advancing to
such an occurrence could manufacture a boundary and bypass acknowledged events.
Any future salvage tool would need its own explicitly authorized policy and is
outside this RFC; it must not be confused with successful normal recovery.

## 3. Framing version

Version `1` means exactly this byte layout, CRC algorithm/coverage, integer
encoding, hard size bound, and structural rules. These cannot change silently
under version 1. Raising the format hard bound or changing CRC coverage requires
a new framing version, even when field widths would still accommodate it.

Version `0` is permanently invalid. Values `2..255` are unsupported by a v1
decoder. Once magic and the version byte are available, reject an unsupported
version immediately. Do not assume its header is 24 bytes, verify it with v1
CRC rules, consume its advertised size, fall back to v1, or continue replay.
The magic/version prefix remains the identification convention for future Tay
framing versions; a different prefix is simply an unknown file/record format.

A bit flip in the version can therefore report unsupported framing rather than
header corruption. This is deliberate fail-closed error precedence, not a claim
that the bytes really came from a newer writer. Storage remains untouched.

## 4. Record type and the physical/semantic boundary

The numeric type space is `0..255`. Reserve `0` and `255` permanently; assign
`1..254` through future event RFCs. There are no private/vendor ranges, escape
types, padding records, or implicit no-op types in v1. Never reuse an assigned
type number for a different meaning. Exhausting the space requires a reviewed
framing extension/version, not repurposing existing values.

This RFC assigns **no production job-event numbers**. The physical codec accepts
every type in `1..254` paired with every schema in `1..255`, provided the other
framing, integrity, and limit checks pass. It MUST NOT consult a semantic event
registry, application configuration, loaded modules, or payload contents to
decide whether those numeric values are acceptable. This applies equally to
encoding and decoding; there is no semantic-support option or strict-mode gate.

For example, `Tay.Storage.Record.decode(bytes)` may return the following for a
complete, physically valid type 47/schema 3 record, even if no Event decoder
understands that pair:

```elixir
{:ok,
 %Tay.Storage.Record{
   format_version: 1,
   record_type: 47,
   flags: 0,
   payload_schema_version: 3,
   sequence: 1,
   payload: <<>>
 }, rest}
```

This success says nothing about the payload's meaning or permission to replay
it. After physical decoding and sequence continuity validation, the **Event
codec** must check whether the type is known, whether that type's schema is
supported, and whether the payload is valid, in that order. Its approved
capabilities must not be inferred from encountering a number on disk. The
representation of those capabilities and the Event API belong to the payload
RFC, not this framing codec.

Unknown types or unsupported schemas stop normal recovery before projecting
that event. Storage MUST remain untouched, and later records MUST NOT be
replayed past that failure. No v1 type is implicitly safe to skip. A future
optional-event facility would need a separate design demonstrating semantic
independence; physical acceptance here provides no such facility.

Fixture identifiers exercise numeric values only; they do not allocate real
events or authorize production replay of their opaque test payloads.

## 5. Flags

Only `FLAGS = 0x00` is supported. All eight bits are reserved for mandatory
interpretation; any nonzero byte returns `unsupported_flags` after header CRC
validation. No optional/ignorable bit range is designated now.

Future readers may explicitly support a new flag under reviewed semantics, but
older readers must stop. A flag must not silently change framing boundaries,
checksum rules, or size bounds under version 1; such changes require a framing
version change. No codec option may mask out unknown bits. The encoder in this
RFC emits only zero flags.

## 6. Payload schema version

Schema versions are **per record type**: `(RECORD_TYPE, PAYLOAD_SCHEMA_VERSION)`
identifies the payload contract. Version 1 of one event says nothing about
version 1 of another. `0` is invalid; `1..255` are available for that type's
reviewed schemas. This RFC does not approve any production payload schema.

Framing version determines where bytes and checksums are. Payload schema version
determines how a future event codec interprets the already framed payload.
Neither can substitute for the other. Header schema IDs do not trigger automatic
deserialization or loading of modules.

Future schema documents must specify compatibility, required fields, and
unknown-field behavior. An incompatible change gets a new schema ID; existing
schema IDs are not reinterpreted. Event decoders support explicitly defined
schema IDs, not every ID lower than some maximum. The physical Record codec
accepts every nonzero schema ID, regardless of Event support. An unknown schema
required for replay stops replay in the Event layer without changing storage,
even though the physical record decoded successfully.

## 7. Sequence

Use an unsigned 64-bit log sequence number. A fresh log starts at `1`; `0` is
reserved and invalid on disk. Consecutive records advance by exactly one across
the whole log, including segment boundaries. Rotation never resets the sequence.
This is a log coordinate, not a job ID, timestamp, or acknowledgement marker.

The maximum uint64 value is legal as a final record. Before trying to allocate
its successor, the future writer must return `:sequence_exhausted` and stop
accepting appends. It must not wrap, reuse zero/one, or create a new segment to
reset the counter. No sequence allocator is part of Phase 1.

`Record.decode/1` and `Record.decode/2` validate only the individual nonzero
field. Stream continuity is the reader/replay layer's responsibility, after
physical record validation and before Event capability/payload validation and
projection. Given last accepted sequence `P`, expect `P + 1`:

| Actual sequence Q | Stream classification | Required replay behavior |
| --- | --- | --- |
| `P + 1` | Contiguous | May proceed to semantic validation |
| `P` | Duplicate | Stop; do not silently deduplicate |
| `< P` | Decreasing/out of order | Stop |
| `> P + 1` | Gap | Stop; do not synthesize missing records |
| Any next record after uint64 maximum | Exhausted sequence space | Stop |

For an initial full replay, use `P = 0` only as an in-memory sentinel. A first
record numbered 2 is a gap. After a future independently validated snapshot at
sequence S, the replay suffix starts at `S + 1`. The first observed segment must
not be allowed to choose an arbitrary starting sequence that conceals prefix
loss. Its proposed `FIRST_SEQUENCE` must agree with the expected coordinate
derived from the previous segment or validated snapshot, and with its first
record. Empty-segment and snapshot anchor validation belong to later RFCs.

Do not add `previous_sequence`: the prior accepted coordinate is already known
to the replay layer. Sequence comparisons alone do not detect replacement by a
different valid record having the same sequence or clean loss of a final suffix.

## 8. Payload length and four different limits

Retain a uint32 big-endian payload length. It counts only payload bytes.

| Limit | Value/policy | Effect |
| --- | --- | --- |
| Representable uint32 maximum | `4_294_967_295` (`0xFFFFFFFF`) payload bytes | Field capacity only; not a legal v1 payload maximum |
| Format hard maximum | `16_777_216` (`0x01000000`) payload bytes | Maximum complete record is `16_777_244` bytes, including 28-byte overhead |
| Configurable insertion maximum | To be chosen before insertion is implemented; must not exceed format maximum | Reject new oversized submissions before encoding; never used by replay |
| Decoder resource limit | `max_decode_payload_bytes`, integer `0..16_777_216`, default `16_777_216` | Explicit resource-limit failure for larger valid records; never corruption/repair permission |

The 16 MiB payload bound gives substantial room for job metadata/arguments while
preventing a nominally valid 4 GiB record from dictating parser buffering. This
is a conservative design bound, not a workload benchmark or a recommendation
to enqueue 16 MiB arguments routinely. Zero-length payloads are structurally
valid; future event schemas may impose their own minimums.

Check the hard maximum **after header CRC verification and before payload
availability, slicing by N, allocation based on N, or waiting for N bytes**.
Use checked arithmetic when computing `28 + N`; Elixir integers can represent
this without overflow, and ports to fixed-width languages must not wrap.

Changing insertion configuration cannot make historical records unreadable.
An intentionally smaller decoding resource budget can stop reading with an
explicit operational error; increasing that budget must permit retrying the
same untouched bytes. Do not truncate a buffer at that budget and call the
result a torn write. The decoder limit applies to the first record's declared
payload, not the combined size of a buffer containing many records. It cannot
undo memory allocation already performed by the caller; the later reader must
use bounded buffering. No limit option is added to Phase 0's `Tay.Config` here.

## 9. Header CRC32C

Use CRC-32C / Castagnoli (also named CRC-32/ISCSI) with these exact parameters:

| Parameter | Value |
| --- | --- |
| Width | 32 bits |
| Polynomial, implicit top term | `0x1EDC6F41` |
| Polynomial, including top term | `0x11EDC6F41` |
| Reflected right-shift polynomial | `0x82F63B78` |
| Initial register | `0xFFFFFFFF` |
| Input reflected (`refin`) | true |
| Output reflected (`refout`) | true |
| Final XOR | `0xFFFFFFFF` |
| Additional zero-byte augmentation | none in the algorithm below |
| Check for ASCII `123456789` | `0xE3069283` |
| Empty-input result | `0x00000000` |
| Stored result | uint32 big-endian; no masking, rotation, or extra complement |

Normative algorithm notation (not production code): initialize a 32-bit register
to all ones; for each input byte in order, XOR it into the low eight register
bits, then perform eight right shifts, XORing `0x82F63B78` after a shift when the
pre-shift low bit was one. Return the register XOR `0xFFFFFFFF`, masked to 32
bits. Do not reflect the result again when using this reflected algorithm.

Compute `HEADER_CRC32C = CRC32C(bytes[0:20])`, covering offsets **0 through 19**
exactly. This includes magic, version, type, flags, schema, sequence, and length.
Offsets 20 through 23 are excluded, not replaced by zeros. Neither payload nor
record checksum is included. Compare numerical CRC values decoded big-endian.

The Castagnoli polynomial and its error-detection limitations are discussed in
[RFC 3385](https://www.rfc-editor.org/rfc/rfc3385.html). CRC reflection and stored
byte order are distinct choices: Tay deliberately stores the computed integer
big-endian. [RFC 3720, appendix B.4](https://www.rfc-editor.org/rfc/rfc3720.html#appendix-B.4)
shows iSCSI digest bytes in a different order; do not copy that wire order into
Tay. The following numerical cross-checks also appear in
[Google's CRC32C tests](https://github.com/google/crc32c/blob/main/src/crc32c_unittest.cc):

| Input | CRC integer | Tay big-endian bytes |
| --- | --- | --- |
| 32 zero bytes | `0x8A9136AA` | `8a 91 36 aa` |
| 32 bytes of `FF` | `0x62A8AB43` | `62 a8 ab 43` |
| Bytes `00..1F` | `0x46DD794E` | `46 dd 79 4e` |
| Bytes `1F..00` | `0x113FDB5C` | `11 3f db 5c` |

CRC32C is not interchangeable with IEEE CRC-32. An implementation must pass
these vectors before using any library, CPU instruction, or incremental API.
An optimized backend may change implementation, never algorithm parameters.

## 10. Record CRC32C

Use the same algorithm with a fresh initial register. Define:

```text
H = bytes[0:20]
P = bytes[24:24+N]
HEADER_CRC32C = CRC32C(H)
RECORD_CRC32C = CRC32C(H || P)
record = H || uint32_be(HEADER_CRC32C) || P || uint32_be(RECORD_CRC32C)
```

The full record CRC excludes **both checksum fields**, with no placeholder bytes.
It includes every interpretation-changing header field and all payload bytes.
It excludes trailing records, segment headers/footers, and filesystem padding.
If N is zero, both stored CRC integers are equal because their inputs are equal;
this is intentional and covered by the minimal fixture.

Including the header CRC in the record CRC would bind the stored header-check
bytes a second time. This offers no necessary check here: those bytes already
must equal the independently computed header CRC. Excluding them keeps the
protected logical input explicit and permits continuing the unfinalized CRC
state over H with P. If a backend exposes only finalized CRC values, its
documented extension convention must reproduce `CRC32C(H || P)` exactly. Do not
XOR the two independent CRC results or feed serialized CRC bytes as the state.

These are two integrity checks with different validation timing, **not** two
independent 32-bit cryptographic guarantees. They use the same polynomial and
overlapping inputs. Do not claim a `2^-64` undetected-error probability. CRCs
detect accidental corruption under stated assumptions; they are not MACs and
do not establish authorship, durability, or completeness of history.

## 11. Codec API and result contract

The Phase 1 module is `Tay.Storage.Record`. Its API consists of
`encode(record)`, `decode(bytes)`, and
`decode(bytes, options)`. `decode(bytes)` is exactly equivalent to
`decode(bytes, [])`. There is no `encode/2`: removing the semantic registry
leaves no encoder options. The only decoder option is its resource budget.

All functions are pure: no semantic registry lookup, GenServer, file I/O, atom
creation from bytes, module loading, sequence allocation, projection, or repair.
Malformed inputs return tagged errors rather than raising; ordinary VM resource
exhaustion is not promised to be catchable by this contract.

### 11.1 Record value

Return a dedicated `%Tay.Storage.Record{}` with exactly these logical fields:

```elixir
%Tay.Storage.Record{
  format_version: 1,
  record_type: type_integer,
  flags: 0,
  payload_schema_version: schema_integer,
  sequence: sequence_integer,
  payload: payload_binary
}
```

`format_version` defaults to 1 and `flags` to 0. Require the other four fields
at struct construction and validate their values at encoding. Length is derived
from `byte_size(payload)`; checksums and magic are computed, not caller supplied.
The struct does not store a disk offset or a `%Tay.Job{}`. A decoded record's
payload is the original byte sequence, with no interpretation or normalization.

### 11.2 Options and argument errors

`encode/1` takes no options. `decode/2` accepts only
`max_decode_payload_bytes: L`, defaulting to the format hard payload maximum.
No registry is accepted or required. In particular there is no insertion-limit,
semantic-support, skip-unknown, resynchronize, or repair option.

Validate the primary argument first: decode requires a byte-aligned binary,
encode requires a `Tay.Storage.Record` struct containing exactly the six declared
fields and its struct tag. Missing/extra fields make it an invalid argument;
malformed struct-shaped maps must not raise while accessing fields. Otherwise return
`{:error, {:invalid_argument, :input}}` or
`{:error, {:invalid_argument, :record}}`, respectively. Iodata, charlists,
non-byte-aligned bitstrings, ordinary maps, and automatic
string/atom conversions are not accepted as alternative input forms.

For `decode/2`, then validate options in this exact order, returning
`{:error, {:invalid_options, reason}}` with the first applicable reason:

1. Not a keyword list: `:not_keyword`.
2. Duplicate option keys: `:duplicate_keys`.
3. Keys other than `max_decode_payload_bytes`: `:unknown_keys`.
4. Decode limit is not an integer in `0..16_777_216`:
   `:invalid_max_decode_payload_bytes`.

Errors contain no raw payload. Caller errors do not classify disk bytes as
corrupt. `decode/1` uses the valid empty option list; `encode/1` has no option
validation or option-error results.

### 11.3 Decode results

```elixir
{:ok, record, rest}
{:incomplete, :header}
{:incomplete, :payload, metadata}
{:incomplete, :checksum, metadata}
{:error, {:corrupt, reason}}
{:error, {:unsupported, reason}}
{:error, {:resource_limit, declared_payload_bytes, allowed_payload_bytes}}
```

Argument/option errors above are additional results. `:ok` certifies a complete
physical record passing framing, structural numeric ranges, both checksums, and
the decoder resource budget, and nothing more. Every assignable type/nonzero
schema pair is eligible for this result. Semantic support, payload meaning,
stream sequence continuity, and valid state transitions are not established.

For an incomplete payload/checksum, metadata is exactly:

```elixir
%{
  format_version: 1,
  record_type: type_integer,
  flags: 0,
  payload_schema_version: schema_integer,
  sequence: sequence_integer,
  payload_length: n,
  record_bytes: 28 + n,
  available_bytes: byte_size(input),
  missing_bytes: 28 + n - byte_size(input)
}
```

These results occur only after the fixed header integrity, structural numeric
checks, and resource budget pass. `available_bytes` includes the header;
`missing_bytes` counts everything still needed for the full frame, including
its final CRC.
Metadata may contain an assignable type/schema unsupported by the Event layer.
It does not establish semantic support or include a partial payload, repair
permission, or proof of durability. CRC-validated does not mean cryptographically
authenticated.

The corrupt reasons are exactly:

```elixir
:invalid_magic
{:invalid_format, 0}
:header_checksum
{:reserved_type, 0}
{:reserved_type, 255}
{:invalid_schema, 0}
{:invalid_sequence, 0}
{:payload_length_exceeds_format, n, 16_777_216}
:record_checksum
```

The codec's unsupported reasons concern physical interpretation only and are
exactly:

```elixir
{:format, version}          # 2..255
{:flags, flags}             # nonzero
```

Unknown semantic type/schema failures belong exclusively to the later Event
layer. They are neither corrupt-record reasons nor unsupported results of
`Tay.Storage.Record`. Reserved type values and schema zero remain structural
errors, as listed above.

On error or incomplete input, the function returns no remainder and consumes
no bytes: the caller retains the entire original input at the same stream
offset. Incomplete input may be retried with additional bytes from that same
position. Corrupt or unsupported input stops normal replay. Resource errors
permit retry only with adequate resources at the same position. None of these
results authorizes truncation, skipping, padding, or overwriting.

On physical success, `rest` identifies the next physical boundary; it does not
authorize replay to pass an unsupported event. The replay caller must retain
the current record and its source position through continuity and Event
validation. An Event failure stops there without projecting that record,
processing later records for replay, advancing an applied checkpoint past it,
or modifying storage. A physical parsing cursor is not a replay checkpoint.

### 11.4 Encode results and validation

`encode/1` returns `{:ok, binary}` or a tagged error. It never reports persistence
or assigns a sequence. After argument validation, check primitive fields
in order: `format_version`, `record_type`, `flags`, `payload_schema_version`,
`sequence`, `payload`. The first four must be uint8 integers, sequence must be a
uint64 integer, and payload must be a byte-aligned binary. Negative integers,
out-of-width integers, floats, nils, and atoms are invalid. Report the first
invalid primitive as `{:error, {:invalid_record, {:field, field_name}}}`.

Derive N from the payload's actual length. Apply the physical domain checks in
§12 step 2 followed by steps 5 through 9, omitting all input-availability/CRC
checks. Unsupported results are the same as decode. Domain failures use
`{:error, {:invalid_record, reason}}` with the corresponding corrupt reason
listed above, such as `{:invalid_sequence, 0}` or
`{:payload_length_exceeds_format, n, 16_777_216}`. No insertion limit is consulted.

Assignable unknown type/schema pairs encode successfully under these same
physical rules. Encoding is not Event validation or application-level admission
to the durable log; production writers must obtain approved, validated events
from the Event layer before framing them.

On success, construct H in table order, calculate both CRCs as §9/§10 specify,
and emit exactly `H || header_crc_be || payload || record_crc_be`. Do not truncate
integers, insert padding, canonicalize payload bytes, or emit partial success.
For fixed input fields and payload the output is byte-identical, independent
of architecture, `%Tay.Job{}`, semantic registry membership, application
configuration, or loaded workers.

## 12. Exact decoder validation order

The order is normative, including which error wins when several faults coexist.
Let B be the input byte length. A return ends this invocation immediately.

0. Perform argument/option validation in §11.2 before examining framing bytes.
1. Compare available bytes at offsets `0..min(B,4)-1` with the corresponding
   magic prefix. Any mismatch returns `{:error, {:corrupt, :invalid_magic}}`.
   If `B < 4`, return `{:incomplete, :header}`.
2. If `B < 5`, return incomplete header. Otherwise inspect byte 4: zero returns
   `{:error, {:corrupt, {:invalid_format, 0}}}`; values `2..255` return
   `{:error, {:unsupported, {:format, version}}}`. Only value 1 continues.
3. If `B < 24`, return incomplete header. Do not validate type/schema/flags,
   trust length, or report payload incompleteness from a partial header.
4. Compute CRC32C over exactly bytes 0..19; compare to the big-endian value at
   20..23. Mismatch returns corrupt `:header_checksum`. The fixed 24-byte check
   has no dependency on PAYLOAD_LENGTH. Interpret the remaining metadata only
   after this comparison passes.
5. Nonzero flags return unsupported `{:flags, flags}`.
6. Type 0 or 255 returns corrupt `{:reserved_type, type}`.
7. Schema 0 returns corrupt `{:invalid_schema, 0}`.
8. Sequence 0 returns corrupt `{:invalid_sequence, 0}`.
9. Length N above `16_777_216` returns corrupt
   `{:payload_length_exceeds_format, n, 16_777_216}`. Now compute `28 + N`.
10. N above the decoder resource budget L returns
    `{:error, {:resource_limit, n, l}}`, even if the payload is also incomplete.
11. If `B < 24 + N`, return incomplete payload with the metadata in §11.3.
12. If `B < 28 + N`, return incomplete checksum with that metadata. For N=0,
    exactly 24 available bytes reach this step, not incomplete payload.
13. Verify the CRC over bytes 0..19 followed by exactly N payload bytes against
    the big-endian CRC at `24+N..27+N`. Mismatch returns corrupt `:record_checksum`.
14. Return `{:ok, record, bytes[28+N:B]}` without consulting semantic support.
    Outside this invocation, replay checks sequence continuity, then Event
    type/schema support and payload validity, then projection/state transition.

A full v1 header with a flipped type/flag/schema/length byte and an unchanged
header CRC fails at step 4, before any structural field or length-based outcome.
An unsupported framing prefix stops at step 2 because the decoder cannot assume
that v1 header offsets apply. Unsupported framing/flags can still be rejected
before a full record arrives; that result makes no claim about its unexamined
tail. Assignable type/schema values cannot cause early rejection by this codec.

Thus a record with semantics unknown to the application can return incomplete,
resource-limit, or checksum failure before any Event validation occurs. With a
complete, physically valid record and sufficient budget, it instead returns
`:ok`, regardless of semantic support. No such physical result is evidence of
Event support, and an incomplete result never authorizes truncation. The old
registry checks are removed, not moved elsewhere within the physical codec.

## 13. Trailing bytes and stream semantics

`decode/1` and `decode/2` process **one record at input offset zero**. On success
they return all remaining bytes unmodified, including any malformed bytes. A
physical parsing cursor can advance by `28 + byte_size(record.payload)` after
successful decoding. Normal replay MUST additionally pass continuity and Event
validation before accepting that event and proceeding to a later record; the
returned remainder alone never authorizes that progression.

- `valid A || valid B`: first call returns A and all of B; the next returns B.
- `valid A || malformed bytes`: first call succeeds with A and those untouched
  bytes; the next call classifies them without skipping anything.
- `valid A || exact prefix of B`: A succeeds; the next call is incomplete unless
  an already visible magic/version violation takes precedence.
- `valid A || physically valid unknown-semantic B || valid C`: physical decoding
  of B succeeds and returns C unchanged. After continuity passes, Event
  validation rejects B; normal recovery stops without projecting B, replaying C,
  skipping B, or changing storage. A read-only framing inspection may examine C
  at that exact boundary, but is not successful recovery or semantic replay.
- A standalone complete frame returns `rest = <<>>`.
- Calling decode on `<<>>` returns incomplete header. A reader at physical EOF
  with no leftover bytes at a known record boundary may report clean end of its
  record area. The decoder itself has no EOF or filesystem knowledge.

Do not drop a remainder when returning success to a higher-level caller. Do not
treat all short remainders as harmless noise. A lone `54` is a possible magic
prefix; a lone `00` at a record boundary is corrupt. Neither authorizes repair.
The reader must retain incomplete bytes when reading another bounded chunk.
Do not pass a footer to the record parser and then reinterpret invalid magic as
permission to delete that footer; §19 assigns envelope handling to Phase 2.

## 14. Payload opacity and semantic separation

The record codec handles arbitrary `binary()` payloads, including NULs, magic
substrings, invalid UTF-8, and bytes that happen to resemble serialized terms.
It must not sniff, decode, validate, compress, decompress, normalize, or execute
payload contents. An empty payload is structurally valid independent of whether
any future event type will allow it.

```text
Record codec: physical framing, structural ranges, limits, checksums
    -> sequence continuity
    -> Event codec / semantic capability validation:
         known record type?
         supported schema for that type?
         valid payload under that schema?
    -> Projection: valid state transition
```

The Record layer MUST NOT require knowledge of currently supported semantic
events, even indirectly through caller-supplied options. Its success is physical
validity, not replay readiness. The Event layer owns the mandatory semantic
capability gate. It must reject an unknown type or unsupported schema before
attempting payload interpretation under an assumed schema; no fallback, skip,
or implicit no-op is permitted. A supported pair can still carry an invalid
payload. Each such failure stops replay before projecting that event, and
normal recovery leaves storage untouched on unknown type/schema.

The layers must not collapse their classifications: unknown semantics are not
physical corruption; reserved type 0/255 and schema 0 are physical errors.
Sequence errors precede Event validation by design. No layer's classification
alone grants recovery repair authority. Replay must not publish a partially
recovered engine or bypass the Event layer because a record has valid CRCs.

No ETF, CBOR, MessagePack, Protobuf, or custom event encoding is selected. ETF
remains specifically unapproved. No `%Tay.Job{}` fields, runtime atoms, module
availability, ID representation, timestamp units, or worker callback returns
define durable bytes. The payload RFC must precede the first stable real job
event. Codec tests and fixtures use opaque bytes and numeric identifiers without
semantic registries or runtime dependencies.

## 15. Adversarial analysis

In this table, **C(reason)** means `{:error, {:corrupt, reason}}` and
**U(reason)** means `{:error, {:unsupported, reason}}` from the physical codec.
Event-layer failures are labeled separately; their exact API belongs to the
payload RFC. A bit-flip case means
exactly one changed bit in a previously valid complete record, with other bytes
unchanged and sufficient decoder resources. For header tears, k is the retained
prefix length of an otherwise physically valid v1 record, independent of Event
support. Event-layer rows assume sufficient decoder resources and contiguous
sequences so that those checks do not stop replay first.

The parser never repairs in any row. **Deferred** in the repair column grants
no permission: only a future Phase 3 RFC may authorize a repair after proving
its preconditions from segment state and the documented failure model.
**No** means the observed condition must not be silently repaired during normal
replay under the accepted requirements. Success is not repair permission either.

| Attack/failure | Detectable? | Classification | May parsing/replay continue? | Automatic recovery repair? |
| --- | --- | --- | --- | --- |
| Bit flip in magic | Yes | C(`:invalid_magic`) | No; never scan forward | No |
| Bit flip in version 1 | Yes as an invalid/unsupported prefix | C(`{:invalid_format, 0}`) or U(`{:format, v}`) | No; do not assume v1 layout | No |
| Bit flip in record type | Yes | C(`:header_checksum`) | No | No |
| Bit flip in flags | Yes | C(`:header_checksum`) | No | No |
| Bit flip in schema version | Yes | C(`:header_checksum`) | No | No |
| Bit flip in sequence | Yes | C(`:header_checksum`) | No | No |
| Bit flip in length | Yes before using N | C(`:header_checksum`) | No | No |
| Bit flip in header CRC | Yes | C(`:header_checksum`) | No | No |
| Bit flip in payload | Yes for N greater than zero | C(`:record_checksum`) | No | No |
| Bit flip in record CRC | Yes | C(`:record_checksum`) | No | No |
| Torn header at each k in `0..23` | Prefix incompleteness detectable, cause not proven | `{:incomplete, :header}` | Only retry same position with more bytes | Deferred; an empty stream at a known boundary needs no repair |
| Torn payload, k in `24..24+N-1` | Incompleteness detectable for N greater than zero | `{:incomplete, :payload, metadata}` | Only retry same position | Deferred |
| Torn final checksum, k in `24+N..27+N` | Incompleteness detectable | `{:incomplete, :checksum, metadata}` | Only retry same position | Deferred |
| Duplicated record | Not by stateless framing; yes by continuity | Each frame may be `:ok`; replay detects duplicate sequence | Stop at duplicate before projection | No silent deduplication |
| Missing middle record with a later sequence present | Yes by continuity | Frames may be `:ok`; replay detects gap | Stop at first unexpected sequence | No |
| Reordered records | Yes by continuity | Frames may be `:ok`; replay detects gap/decrease/duplicate | Stop at first deviation | No |
| Clean deletion of the final record/suffix | Not from remaining record bytes alone | Surviving prefix may be entirely valid | Parser can finish surviving prefix; cannot certify completeness | No automatic reconstruction; data is absent |
| Random bytes between records | Usually; not an absolute guarantee | Invalid magic/header/record or unsupported data; short matching prefix may be incomplete | Stop at first non-success; never hunt for next record | No for errors; incomplete cases deferred |
| Random bytes appended after a valid record | Usually; valid-looking prefixes/collisions are possible | Prior record succeeds with untouched remainder; next call classifies it | Prior record only; no bypass of remainder | No for errors; incomplete cases deferred |
| Valid older record then unsupported newer framing | Yes once next prefix has a version | First succeeds; next U(`{:format, v}`) | Stop at newer record | No; storage untouched |
| Physically valid v1 record with assignable unknown type | Yes in Event layer, not a framing defect | Record `:ok`; Event rejects unknown type | Physical inspection can continue at returned boundary; normal replay must stop before this event's projection | No; storage untouched |
| Physically valid v1 record with known type and unsupported nonzero schema | Yes in Event layer, not a framing defect | Record `:ok`; Event rejects unsupported schema | Physical inspection can continue; normal replay must stop before this event's projection | No; storage untouched |
| Physically valid record with supported type/schema but invalid payload | Yes in Event payload validation | Record `:ok`; Event rejects payload | Normal replay stops before projection; never silently discard event | No implicit repair |
| Unknown-semantic type/schema with incomplete payload or checksum | Physical incompleteness detectable; Event support not yet checked | Record incomplete with numeric metadata | Only retry same position; not a safe-to-drop unknown event | Deferred; incomplete alone never authorizes repair |
| Unknown-semantic type/schema with damaged record CRC | Yes physically before Event validation | C(`:record_checksum`) | Stop; do not relabel it semantic unsupported or skip | No |
| Reserved type 0/255 or schema 0 with matching CRCs | Yes structurally | C(`{:reserved_type, t}`) or C(`{:invalid_schema, 0}`) | Stop in Record layer | No |
| Nonzero flags with recomputed CRCs | Yes as unsupported physical interpretation | U(`{:flags, f}`) | Stop in Record layer | No; storage untouched |
| Valid large record over decoder budget | Yes | `{:error, {:resource_limit, n, l}}` | Retry same position with sufficient budget | No |
| Correlated/forged changes including matching CRCs | Not always | May be `:ok`, incomplete, or unsupported depending on resulting bytes | No authenticity/completeness guarantee | Never authorized by CRC/incomplete alone |
| Valid record transplanted from another log with matching sequence | Not necessarily at record level | May be `:ok` and pass continuity | Requires separate identity/provenance protections if in threat model | No implied repair |

For random bytes, a coincidental physically valid record is indistinguishable
from another valid record at this layer. No probability estimate is a proof of
its origin. A single-bit detection guarantee must not be generalized to arbitrary
multi-field changes or simultaneous checksum replacement.

An incomplete prefix in a sealed segment is not evidence of an ordinary active
tail append. Segment validation must treat it as sealed-history failure. This
RFC does not authorize trimming it or removing the footer to reopen the segment.

## 16. Data-loss analysis and the corrupted-length proof

### 16.1 The A/B/C scenario

Assume original valid records `[A][B][C]`, an intact full header for B except
for changes confined to its four PAYLOAD_LENGTH bytes, and B's original stored
header CRC unchanged. The decoder reaches B only at the known boundary after A.

1. It obtains the fixed 24-byte header without using N.
2. It calculates the header CRC over a fixed 20-byte input.
3. Any nonzero change confined to the four length bytes occupies a burst of at
   most 32 bits. A degree-32 CRC generator with nonzero constant term detects
   every such nonzero burst: the nonzero error polynomial has degree below 32,
   so cannot be divisible by the generator; shifting its position does not
   change that conclusion. Initial/final XOR terms cancel when comparing these
   equal-length headers. This is a property of CRCs, not a statistical guess.
4. Therefore step 4 returns C(`:header_checksum`) before interpreting the
   corrupted N, even if N would otherwise exceed remaining bytes or swallow C.
5. The decoder returns no success/remainder/repair authorization for B; a
   conforming replay caller stops and preserves B and C.

The same early check catches any single-bit mutation elsewhere in the protected
header, except magic/version may reject even earlier by the specified precedence.
The burst-error basis and limitations are discussed in
[RFC 3385](https://www.rfc-editor.org/rfc/rfc3385.html#section-4).

This proves the requested length-only case. It does **not** prove detection of
arbitrary correlated corruption of other header fields and checksums. A 32-bit
CRC over 160 input bits has collisions. An attacker can also change N and
recompute its CRC. If the forged header passes the structural and hard-limit
checks, a larger N may yield incomplete payload. That result still cannot be
mistaken for a *safe* torn tail by any conforming caller: this RFC never equates
incomplete with repair permission. An unconditional claim that every possible
corrupted header is detected is impossible with this checksum model.

### 16.2 Plausible implementations that would lose data

| Incorrect implementation | Concrete failure | Required prevention |
| --- | --- | --- |
| Read N before validating header CRC | Corrupt B length points beyond EOF; truncation deletes B and C | Fixed header CRC first; reject corruption |
| Convert every short read/error into torn tail | Corrupt bytes, unsupported future records, or a resource cap discard acknowledged records | Preserve the distinct result classes; no error-to-incomplete conversion |
| Use current insertion limit as replay limit | Lowering configuration makes an older large record look invalid | Fixed format maximum; independent insertion/resource limits |
| Drop decoder remainder | Valid A succeeds while B/C disappear from replay | Return and process every trailing byte at the exact next boundary |
| Scan for magic after failure | Magic embedded in B's payload or C is treated as the next boundary | No resynchronization or implicit skip |
| Skip unknown cancellation/completion | Replay sees the earlier job as runnable again | Mandatory Event type/schema validation after physical decoding and continuity, before projection; unsupported flags still stop in Record |
| Treat Record `:ok` or a returned remainder as Event acceptance | A physically valid unknown event is ignored while later events are applied | Separate physical cursor from accepted replay progress; Event validation is mandatory for every event |
| Persist a checkpoint past a merely framed record | Restart resumes after an unknown event that was never understood or applied | Never advance applied/checkpoint state past an Event failure; do not modify storage during failed unsupported-semantic recovery |
| Apply partial replay and start queues anyway | Jobs execute before later cancellation/completion is read or before unsupported history is noticed | Later startup must withhold dispatch/readiness until required replay succeeds |
| Rebase expected sequence from the first remaining file | A missing initial segment is hidden by trusting its successor's FIRST_SEQUENCE | Anchor at initial sequence 1 or an independently validated snapshot |
| Truncate at the configured decoder budget | A full stored frame becomes an artificial partial buffer | Explicit resource error, retaining original bytes and position |
| Repair some files before discovering unsupported semantics later | A failed downgrade has already changed storage | Future recovery must preserve storage on unsupported semantics; repair staging/order belongs to Phase 3 |
| Treat every checksum-valid append as acknowledged/durable | Restart or power loss can lose unsynced file/directory changes | Acknowledgement and sync ordering belong to Phase 2, not this codec |

### 16.3 Fundamentally undetectable or unrepairable classes

Clean loss of a final active-log suffix with no later sequence is indistinguishable
from a log that ended there. A valid-prefix CRC or monotonic sequence does not
record the fact that removed records were acknowledged. A sealed footer or
independent durable metadata may expose a missing suffix if that evidence still
exists, but the record format alone cannot promise this.

Likewise, replacing a whole log with an older consistent copy, forged records
with valid CRCs, or coordinated replacement of records and their surrounding
metadata may remain undetectable. Detection is not reconstruction: even when a
sequence gap exposes missing bytes, this format contains no redundant copy from
which to restore them.

Acknowledged durability depends on the later writer protocol and documented
filesystem/storage assumptions. It cannot be proved by adding another record
offset, timestamp, or CRC. The Phase 3 failure model must bound the circumstances
under which incomplete active tails may be discarded. This RFC authorizes no
automatic truncation, including for the apparently simplest incomplete tail.

### 16.4 Risks exposed by moving semantic validation out of Record

The revision changes an API/result boundary, not wire bytes or integrity
protection. It introduces no new framing ambiguity and does not weaken the
corrupted-length proof. It does expose integration risks previously obscured by
the framing codec's semantic gate:

- **Physical success mistaken for semantic acceptance.** A generic loop over
  Record results can now traverse physically valid unknown events. That is
  useful for read-only framing inspection, but a replay loop that omits the
  mandatory Event gate could silently lose event effects or re-execute jobs.
  Sections 11–14 require the gate before projection and forbid progressing
  replay/checkpoints past a failure or publishing a partially recovered engine.
- **Later unsupported-semantic diagnosis and extra bounded work.** Type/schema
  membership is no longer checked at the header. A complete record must pass
  payload availability and CRC checks before Event validation; an unknown event
  may require up to the existing 16 MiB payload bound to be read and checked.
  A smaller resource budget may stop earlier with an operational error. The
  later reader still needs bounded buffering; there is no larger format limit.
- **Different error precedence must not become repair policy.** A truncated or
  CRC-damaged unknown-semantic record now reports the physical failure first,
  rather than an early unsupported-type/schema result. Continuity failures also
  precede Event checks. No failure proves semantic support or authorizes repair;
  in particular, incomplete unknown-semantic records cannot be presumed safely
  discardable. Phase 3 must preserve the storage-untouched requirement when
  unknown semantics are encountered and separately justify any repair policy.

These are caller-integration and diagnostic-order risks, not new permissions
to mutate storage. With the required pipeline and no-skipping/no-implicit-repair
rules, this revision creates no new data-loss path. No recovery procedure is
approved here; later integration tests in §18 must guard this boundary.

## 17. Compatibility analysis

| Change encountered by an older reader | Required behavior | Compatibility consequence |
| --- | --- | --- |
| New framing version | Unsupported at identification prefix; no replay continuation or modification | Downgrade cannot read it without an explicit supported reader/migration |
| New assignable type under v1 | Record decodes physically valid bytes; after continuity, Event rejects unknown type and recovery stops without mutation | Forward physical readability is not semantic replay compatibility |
| New nonzero schema of a recognized type | Record decodes physically valid bytes; after continuity, Event rejects unsupported schema and recovery stops without mutation | Schema support is per type, not global or inferred from numeric order |
| New flags | Nonzero flags unsupported by this v1 implementation | No unreviewed optional bit can silently change interpretation |
| Lower insertion-size configuration | Replay unchanged for all valid historical frames | Only new submissions are constrained |
| Lower decoder resource budget | Explicit resource-limit error; no mutation | Resume with sufficient resources; no format migration required |
| Changes to `%Tay.Job{}`, worker modules, or Event support | Record bytes decode unchanged regardless of semantic capabilities | Runtime layout, module presence, and event registry membership do not define framing; Event codec handles meaning separately |
| Different CPU endianness/OTP version | Same fields/bytes yield the same CRC integers and encoded bytes | No native-endian or runtime-term serialization is used |
| Wider desired length/type/schema space | Reviewed new framing version, never wrapping/reusing IDs | Existing v1 remains readable according to its original bound/layout |

An older application may read a compatible prefix before finding unsupported
history. It must not publish that prefix as a fully recovered engine. Refusing
startup without changing storage is the safe downgrade behavior; silent
best-effort replay is not compatibility.

An older physical decoder can frame/checksum an entire v1 stream containing
new assignable type/schema values without understanding those events. This is
physical forward readability only: the same application's normal recovery must
stop at its first semantic failure after physical and continuity checks. CRC
success never justifies replaying later supported records past that failure.

Relative to the preceding draft, `encode/2` becomes `encode/1`; `decode/1` is
available with default resources and `decode/2` retains only its resource option.
The former `supported_schemas` option is removed; supplying it to `decode/2`
returns `{:error, {:invalid_options, :unknown_keys}}`. Type/schema membership
errors disappear from Record's result union and become Event-layer failures.
This was a deliberate pre-implementation API correction, not an on-disk migration:
at approval the repository contained no implemented Record API or persisted
records to upgrade. Implementers must not preserve the old gate as hidden global state.

No stable event schema, worker identity representation, job ID encoding, or
payload canonicalization follows from approval of this framing RFC. Numeric
fixture identifiers do not constitute production event allocations. Updates to
real schemas must retain their independently approved decoding contracts and
fixtures; those contracts are outside the physical codec.

## 18. Golden compatibility fixtures and Phase 1 tests

The following literal bytes are permanent compatibility fixtures, stored as fixed files
under `test/fixtures/storage/record/v1/`, with a manifest recording their IDs,
expected physical results, and any decoder resource overrides. No semantic
registry is part of the manifest. Phase 1 creates these fixtures; they are not
regenerated during tests. Do not generate expected bytes using the codec under test.
Whitespace/newlines in the hex below are presentation only.

Unless stated otherwise, use `Tay.Storage.Record.decode(bytes)` with its default
`max_decode_payload_bytes: 16_777_216`. The equivalent `decode(bytes, [])` must
return the same result. Encoding fixtures uses `Tay.Storage.Record.encode(record)`.

These are framing conformance identifiers, not real job events. `:ok` below
means `{:ok, record, <<>>}` and does not claim valid event semantics or continuity
with another standalone fixture. Corrupt/unsupported abbreviations follow §15.

### 18.1 Fixed byte fixtures

**F01 — minimal valid v1 record**, 28 bytes. Type 1, schema 1, sequence 1,
empty payload. Expected `:ok`; both CRCs are `0x44EA307B`.

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 01 00 00 00 00 44 ea 30 7b 44 ea 30 7b
```

**F02 — representative opaque binary**, 37 bytes. Type 1, schema 1, sequence 2,
payload `00 ff 54 41 59 00 7f 80 0a` (9 bytes, including embedded magic and
invalid UTF-8). Expected `:ok`; header CRC `0x746B5B43`, record CRC `0x4E6783E1`.

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 02 00 00 00 09 74 6b 5b 43 00 ff 54 41 59 00 7f 80 0a 4e 67 83 e1
```

**F03 — maximum assignable type, schema and sequence**, 28 bytes. Type 254,
schema 255, sequence `18_446_744_073_709_551_615`, empty payload. Expected `:ok`,
independent of Event support. It is not a valid first record of a new log.

```text
54 41 59 00 01 fe 00 ff ff ff ff ff ff ff ff ff 00 00 00 00 fa 87 5c 6b fa 87 5c 6b
```

**F04 — bad header CRC through a length mutation**, 28 bytes. F01 with offset
19 changed from 0 to 1 and CRCs untouched. Expected C(`:header_checksum`), never
incomplete checksum even though the corrupted length suggests a 29-byte frame.

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 01 00 00 00 01 44 ea 30 7b 44 ea 30 7b
```

**F05 — bad record CRC**, 37 bytes. F02 with its final byte XOR 1. Expected
C(`:record_checksum`).

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 02 00 00 00 09 74 6b 5b 43 00 ff 54 41 59 00 7f 80 0a 4e 67 83 e0
```

**F06 — unsupported framing**, 28 bytes. Version byte 2; the remaining bytes
use v1-like construction only for the negative test. Expected U(`{:format, 2}`)
as soon as five bytes are available. This does not specify an actual v2 format.
The v1 decoder must not inspect the later CRCs to classify it.

```text
54 41 59 00 02 01 00 01 00 00 00 00 00 00 00 01 00 00 00 00 57 12 50 88 57 12 50 88
```

**F07 — assignable type independent of semantic support**, 28 bytes. Type 2,
schema 1 with matching CRCs. Expected physical `:ok`, even when no Event decoder
knows type 2. No Event capability setup is required for this codec fixture.

```text
54 41 59 00 01 02 00 01 00 00 00 00 00 00 00 01 00 00 00 00 ec 79 37 78 ec 79 37 78
```

**F08 — nonzero flags**, 28 bytes. Flag 1 with matching CRCs. Expected
U(`{:flags, 1}`).

```text
54 41 59 00 01 01 01 01 00 00 00 00 00 00 00 01 00 00 00 00 10 ed 65 3d 10 ed 65 3d
```

**F09 — nonzero schema independent of semantic support**, 28 bytes. Type 1/schema
2 with matching CRCs. Expected physical `:ok`, even when an Event decoder knows
type 1 but does not support its schema 2. No Event layer runs in this codec test.

```text
54 41 59 00 01 01 00 02 00 00 00 00 00 00 00 01 00 00 00 00 15 9c 78 d4 15 9c 78 d4
```

**F10 — maximum legal header values including length**, 24 bytes. Type 254,
schema 255, maximum sequence and N=`16_777_216`. The header is complete and
checksummed, but the body is intentionally absent. Expected incomplete payload
with `record_bytes: 16_777_244`, `available_bytes: 24`, and
`missing_bytes: 16_777_220`. This and F03 cover the legal field maxima without
committing a 16 MiB opaque blob as a golden fixture.

```text
54 41 59 00 01 fe 00 ff ff ff ff ff ff ff ff ff 01 00 00 00 27 c2 f6 d3
```

**F11 — representable uint32 maximum is illegal for v1**, 24 bytes. Checksummed
header with N=`4_294_967_295`. Expected
C(`{:payload_length_exceeds_format, 4_294_967_295, 16_777_216}`), without awaiting
or allocating the advertised body.

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 01 ff ff ff ff f3 72 84 43
```

**F12 — just above the format maximum**, 24 bytes. N=`16_777_217` with a valid
header CRC. Expected C(`{:payload_length_exceeds_format, 16_777_217, 16_777_216}`).

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 01 01 00 00 01 6b c4 19 c0
```

**F13 — zero framing version**, 28 bytes. Expected C(`{:invalid_format, 0}`).

```text
54 41 59 00 00 01 00 01 00 00 00 00 00 00 00 01 00 00 00 00 b6 e6 3d 85 b6 e6 3d 85
```

**F14 — reserved type zero**, 28 bytes. Expected C(`{:reserved_type, 0}`).

```text
54 41 59 00 01 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 23 64 cd 7a 23 64 cd 7a
```

**F15 — reserved type 255**, 28 bytes. Expected C(`{:reserved_type, 255}`).

```text
54 41 59 00 01 ff 00 01 00 00 00 00 00 00 00 01 00 00 00 00 32 1c 55 47 32 1c 55 47
```

**F16 — invalid schema zero**, 28 bytes. Expected C(`{:invalid_schema, 0}`).

```text
54 41 59 00 01 01 00 00 00 00 00 00 00 00 00 01 00 00 00 00 74 38 08 1e 74 38 08 1e
```

**F17 — invalid sequence zero**, 28 bytes. Expected C(`{:invalid_sequence, 0}`).

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 7c fb 5f d7 7c fb 5f d7
```

**F18 — third contiguous record**, 28 bytes. Type 1/schema 1, sequence 3, empty
payload. Expected `:ok`. F01, F02, F18 form a contiguous three-record example.

```text
54 41 59 00 01 01 00 01 00 00 00 00 00 00 00 03 00 00 00 00 34 c8 ef 23 34 c8 ef 23
```

The CRC integers in these proposed fixture bytes were calculated in memory
using both a reflected right-shift and a normal-polynomial left-shift formulation
with explicit bit reflection. Both matched the empty/ASCII check and the four
published numerical vectors in §9. These are independently calculated fixture
values, not results from an implemented Tay codec. Physical negative fixtures
must remain negative; do not recompute their CRCs in the test suite. F07 and F09
are now positive physical fixtures: only their expected classifications changed
from the preceding draft, not their bytes. Their unknown-semantic rejection
belongs in later Event/recovery tests, not in Record's fixture expectations.

Additional in-memory arithmetic checks detected all 640 single-bit protected
header mutations across F01/F02/F03/F18. The 32 length-bit CRC-difference vectors
had binary rank 32 with all other header bytes fixed, corroborating the
length-only injectivity argument in §16. These checks validate the proposed
bytes and arithmetic; they are not claims that codec or recovery tests ran.

### 18.2 Required implementation tests beyond fixtures

1. Decode each fixture to the exact result above; encode F01/F02/F03/F07/F09/F18's
   logical values to their literal bytes. Keep decoder and encoder assertions
   separate so they cannot agree on the same accidental format change.
2. Test CRC parameters, big-endian stored bytes, empty input, and equivalence of
   one-shot versus incremental coverage over H and P. A backend must not
   substitute IEEE CRC-32 or append zeros/checksum placeholders.
3. For every k below each valid fixture's full length, test the exact incomplete
   classification in §15. All `0..23` header boundaries are included. Test each
   available magic-prefix mismatch and the immediate version checks at byte 5.
4. Flip each individual bit in each header field, each stored checksum, and the
   representative payload. Assert the exact error precedence, including magic
   and version exceptions. Recompute CRCs in separate constructed cases to
   reach zero/reserved structural checks and unsupported framing/flags. Mutating
   type/schema to another assignable/nonzero value with both CRCs recomputed
   must succeed; it is not an unsupported-semantic case for Record.
5. For the A/B/C test concatenate F01, F02 with its length byte at offset 19
   XOR `0x40` (N changes from 9 to 73), and F18. A decodes successfully; the
   next decode returns C(`:header_checksum`). The entire remaining B/C buffer
   must be retained. Without the header check, the 65 remaining bytes would
   appear shorter than the claimed 101-byte B record.
6. Test concatenated valid frames, valid plus corrupt data, valid plus unsupported
   framing/flags, valid plus assignable unknown-semantic type/schema, and magic
   embedded in payload. Unknown-semantic frames decode successfully and return
   the exact remainder; they must not hide a corrupt or incomplete next frame.
   Test zero-length remainder separately from a nonempty partial header.
   Retrying a prefix plus more bytes must match one-shot decode.
7. Exercise N=0, N=1, N=hard maximum, and one above. Construct the large boundary
   payload deterministically in the test, not by loading historical logs. The
   fixed maximum-length header and an independent CRC calculation anchor that
   boundary. F11/F12 must fail without requiring a large body.
8. Decode F02 with resource budgets 8 and 9: respectively
   `{:error, {:resource_limit, 9, 8}}` and success. Budget 0 accepts F01's empty
   payload. Default/empty options, malformed options, duplicate keys, unknown
   keys (including the removed semantic-registry option), invalid argument
   types, numeric overflows, and negative values must follow §11 exactly.
   `decode/1` and `decode/2` with empty options must agree. No registry is needed
   to encode or decode any physically valid fixture.
9. Verify an unrelated insertion configuration never affects the codec and an
   oversized valid frame under a smaller resource budget is never incomplete
   or corruption. No test may introduce durability configuration in Phase 1.
10. Use property-based round trips over legal numeric fields and arbitrary bounded
    binary payloads, without semantic profiles. Cover every type in `1..254`
    paired with every schema in `1..255` using a small fixed opaque payload;
    include an explicit type 47/schema 3 success assertion without any Event
    implementation. Preserve exact numeric values and bytes on round trip.
    For generated records test truncation boundaries exhaustively on small
    payloads and sample boundaries
    on large ones; no strict prefix may decode as a different complete record.
11. Exercise arbitrary byte-aligned inputs: results must stay in the specified
    union without exceptions from parsing. No generated garbage may create
    atoms, load worker modules, or trigger payload decoding. General arbitrary
    corruption must not be asserted to have zero CRC-collision probability.
12. Test duplicate/reordered/gapped streams at the framing boundary: individual
    valid records still decode and preserve their actual sequence values.
    Continuity enforcement and active/sealed repair cases become integration
    tests when the reader/recovery layer exists; Phase 1 must not add it solely
    to make a codec test claim replay safety.
13. For otherwise legal type/schema values unknown to a future Event layer,
    test incomplete payload/checksum, record CRC failure, and resource-limit
    precedence exactly as for any other physical record. A valid header with
    resource budget below N must return resource-limit before incomplete;
    corrupt payload with sufficient bytes/budget must return record-checksum
    failure, not an unsupported-type/schema result. Metadata must retain the
    original numeric type/schema. No configuration or loaded worker module may
    change these classifications or the successful F07/F09 results.

Required **later Event/recovery integration tests**, not Phase 1 implementation:

- After approving actual Event schemas, verify that changing the Event layer's
  supported set changes semantic acceptance but not Record encoding/decoding.
  Use a test capability set that rejects F07's type or F09's schema to exercise
  rejection at the Event boundary without making that set a Record argument or
  allocating production event meanings to these physical fixture identifiers.
- For contiguous, physically valid A/B/C, make A and C understood by the test
  Event layer and B unknown. Record must decode B and return C unchanged, while
  recovery must stop on B with no B/C projection, skip, applied-checkpoint
  advancement past B, successful startup/readiness, or storage modification.
  Repeat for a known type with an unsupported schema and for supported
  type/schema with invalid payload; the latter must also stop before projection.
- Verify the layer order using physical failure, sequence failure, unknown
  type, unsupported schema, invalid payload, and invalid state transition
  cases. Later validation must not run past an earlier failure, and no physical
  result or semantic failure alone may authorize repair.
- Snapshot storage bytes and file inventory around an unsupported-semantic
  recovery attempt: they must be unchanged, even if an earlier observation
  would otherwise have suggested repair. Repeat with partial unknown-semantic
  records to prove that `incomplete` alone triggers no truncation. Precise
  filesystem durability/repair scenarios remain subject to Phases 2 and 3.

Fixture compatibility starts with Phase 1 approval/implementation. Later schema
fixtures complement these framing fixtures. Format changes require an explicit
version boundary or migration rather than silently updating expected bytes.

## 19. Interaction with the planned segment envelope

The 24-byte record header fits inside the candidate segment model without any
record-layout changes. Record offsets remain relative to the record, not the
file. A first record after a candidate 32-byte segment header begins at file
offset 32; its own offset 0 is still `54 41 59 00`.

Segment header/footer CRCs and their exact coverage remain Phase 2 decisions.
Record CRCs do not cover segment bytes. Conversely, the candidate sealed-segment
integrity layer may bind a whole segment's history; its exact scope is not
silently defined here. The highest-ID active-candidate rule and rotation crash
state machine also remain unapproved candidates.

The segment reader must validate its envelope and supply only the record area
to the record decoder, or explicitly recognize envelope structures at known
boundaries according to the future segment RFC. `TAYS` and `TAYF` are not record
magic. How a footer is located and distinguished from a torn structure must be
settled there; searching arbitrary payload bytes for footer magic is not a
replacement for that design. Records must not be split across segments; the
future writer must rotate before a record if necessary and account for the
envelope/footer overhead when enforcing its segment threshold.

| Proposed additional record field | Needed here? | Reason |
| --- | --- | --- |
| `segment_id` | No | The segment envelope identifies its container; record sequence supplies cross-segment order. Per-record segment IDs would also bind bytes to placement. |
| `previous_sequence` | No | The replay layer already retains the last accepted sequence and checks `+1`. |
| `record_offset` | No | The reader tracks the current file offset and decoded byte count. Persisting it would unnecessarily bind records to physical placement. |
| `timestamp` | No | Time is not needed for framing or continuity. Event time belongs to a future payload schema, including its clock/unit semantics. |

`FIRST_SEQUENCE` in a segment header and the first record's sequence are useful
cross-checks, not a reason to remove record sequences. Every record needs its
own coordinate to expose missing/duplicated/reordered entries within the file.
Record sequence alone does not bind a record to a particular storage instance.
If cross-store substitution is in scope, the Phase 2 RFC must address storage
identity/provenance or explicitly document the limitation; a per-record segment
ID by itself would not solve replacement with the same ID from another store.

No segment files, envelope code, writer, footer parser, or rotation code are
created by this RFC. Segment resource thresholds must accommodate the approved
record maximum or reject new writes explicitly without changing replay validity.

## 20. Final recommendation and decisions assigned to later RFCs

Retain the current 24-byte header and 28-byte total overhead. Each field has a
concrete role: identification, framing compatibility, semantic dispatch, flags,
per-type schema compatibility, logical order, bounded payload framing, and early
header integrity. The trailing CRC covers the complete logical record. No
additional field resolves the acknowledged-suffix-loss limitation, and no
existing byte can be removed without losing one of these responsibilities.

The already approved physical format, limits, CRCs, sequence design, and fixture
strategy remain unchanged. Approval includes the pure physical opaque codec
API/result boundary and places mandatory semantic capability validation in
the future Event layer after continuity. It does not approve
an event schema, filesystem guarantee, or repair procedure. The length-only
corruption proof is conditional exactly as stated in §16; arbitrary
CRC collisions and clean suffix loss are explicit limitations of the design.

Remaining **payload RFC** decisions:

- Canonical serialization, production event type allocation, and per-type
  schema definitions, including semantic validation and schema evolution.
- Durable worker identities, job IDs, timestamps/units, argument/error/result
  restrictions, and independence from runtime atoms/modules and `%Tay.Job{}`.
- Payload decoding resource policies and any future compression, plus the Event
  codec's capability representation, validation API, and semantic failure
  contract. None belongs in Record's options. ETF remains unapproved.

Remaining **Phase 2 segment RFC** decisions:

- Final segment header/footer layout, CRC coverage, reserved fields, naming,
  storage identity, record-area boundaries, empty segments, and sealed status.
- Single-writer/data-directory ownership, sequence allocation across failed
  appends/restarts, segment size thresholds, and handling a maximum-sized record.
- Exact file/directory sync and acknowledgement semantics on supported
  platforms; short writes, I/O errors, and the reviewed rotation crash matrix.

Remaining **Phase 3 recovery RFC** decisions:

- Failure model and evidence required to authorize any repair; incomplete is
  never sufficient by itself, and unsupported semantics must preserve storage.
- Discovery/continuity validation, active versus sealed cases, crash points
  during repair/rotation, and safe ordering before publishing recovered state.
- Replay anchors, future snapshot integration, sequence-error reporting, and
  operational treatment of corruption, missing files, and resource-limit errors.

There are no remaining physical framing/codec choices delegated to the engineer
implementing an approved version of this RFC. Record accepts every assignable
type/nonzero schema without consulting semantic support. Event validation is
mandatory downstream, and unknown semantics still stop recovery without
changing storage. Real event meanings and filesystem operations remain separate
work. The integration risks in §16.4 do not require a header change. This is the
design recommendation, now approved for Phase 1 only:

**APPROVE CURRENT 24-BYTE HEADER**
