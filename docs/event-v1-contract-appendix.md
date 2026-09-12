# Appendix: production Event v1 contract

Status: **normative specification submitted for approval; no implementation authorized.**
Parent: [accelerated roadmap](production-roadmap-rfc.md). This closes its R2
specification and fixes only the constants/details required by approved R3.
R1/R3/R4 and G1–G6 are settled, not reopened. Record v1 and Segment/STORE v1
remain byte-identical. MUST/MUST NOT below govern the implementation once approved.
All numeric constants are decimal unless explicitly hexadecimal.

## A. Binary value encoding

One payload is exactly one value: an Event map. There is no payload preamble,
padding, terminator, compression, ETF, reference graph or implicit extension.
All multi-byte fields are big-endian. Lengths count bytes, not characters.

| Hex tag | Exact body / legal value |
| --- | --- |
| `00` | No body; nil |
| `01` | No body; false |
| `02` | No body; true |
| `03` | Eight-byte two's-complement int64, **strictly negative**: −2^63..−1 |
| `04` | Eight-byte uint64: 0..2^64−1; the only representation of nonnegative integers |
| `05` | Eight-byte IEEE binary64 bits; exponent must not be 2047 |
| `06` | uint32 length, followed by exactly that many UTF-8 bytes |
| `07` | uint32 length, followed by exactly that many opaque bytes |
| `08` | uint32 element count, followed by exactly that many encoded values |
| `09` | uint32 pair count, followed by encoded text-key/value pairs |
| `0a`..`ff` | Invalid value tag; never skip or guess its length |

Floats preserve **all finite bits**, including signed zero and subnormals. No
NaN/infinity, rounding, flushing subnormals, converting integral floats to ints,
or collapsing −0.0 to +0.0. Thus integer 0, +0.0 and −0.0 are three distinct
canonical encodings. Immutable-definition comparison uses canonical bytes, not
runtime numeric equality. A runtime unable to preserve these bits must fail
provider initialization as an operational incompatibility, never normalize
stored values or classify otherwise valid bits as corrupt data.

UTF-8 means shortest-form encodings of Unicode scalar values U+0000..U+10FFFF,
excluding U+D800..U+DFFF. Reject overlong forms, lone continuations, incomplete
scalars and values above U+10FFFF. Noncharacters, U+0000 and BOM are valid text
unless a field below restricts them. No replacement decoding, BOM stripping,
normalization, trimming, case folding or locale-dependent comparison.

Map keys MUST be tag `06`, unique, and strictly ascending by unsigned UTF-8
**body bytes**, lexicographically; shorter prefix sorts first. Compare decoded
key bytes, not their length prefixes or locale collation. No duplicate-key
last-wins behavior. Empty text/list/map are legal values.

Tag `07` is legal in Event v1 only for `job_id`; arbitrary bytes are not args.
Args are a tag-`09` map with text keys and recursively nil/bool/int/finite-float/
text/list/map values. Runtime structs, arbitrary atoms, tuples, PIDs, references,
functions and modules have no representation. Nil/booleans and fixed internal
enum names may map to built-in runtime values; disk strings never create atoms.

### Counting and validation

- Root depth is 1. Each map key, map value or list element is at parent depth + 1.
  Empty containers still have their own depth. Keys do not add an extra nesting
  layer around their associated values.
- Count one node per scalar/container **and per map key**, including nil, bool
  and the root. No node deduplication or sharing discount.
- `binary_bytes` is the sum of all tag-`06`/`07` body lengths, including repeated
  field names and map keys. Do not count tags, length prefixes or numeric bodies.
- No additional persisted generic depth/node/text-size ceiling is introduced.
  uint32 counts/lengths and Record's 16,777,216-byte payload hard limit bound
  representability; §F budgets bound execution. Field-specific limits below are
  immutable **semantic** constraints, not Record framing limits.
- Decode left-to-right. Before visiting a node, check depth/node budget; then
  its tag and required fixed bytes. Check declared body availability and checked
  arithmetic before slicing/allocation; charge text/binary budget before copying
  or UTF-8 decoding. Container counts must fit the remaining minimum bytes
  (one byte per list item; six per map pair) and remaining minimum node budget
  before traversal/allocation. Visit/count actual child nodes once, not twice.
- After value decoding, require zero remaining payload bytes, then exact schema
  fields/domains, then state-dependent transition validation. A successful
  `decode_payload/4` returns consumed count exactly `byte_size(payload)`.
  Truncated **value** bytes inside a complete physical Record are invalid payload,
  never an incomplete Record or repair authorization. With insufficient budgets,
  a resource error may precede discovery of later malformed bytes.

## B. Six Event schemas

Types 1–6 below each support **payload schema ID 1 only**. Symbolic names in
tables are documentation/internal names; no atom or event-name string is stored.
The type/schema already live in the unchanged physical header and are not
duplicated in the payload. Every listed key is required; every unlisted key is
invalid, at every schema-controlled map level. Nil is allowed only where stated.

| Domain | Exact wire/value constraint |
| --- | --- |
| `U` | Tag `04`, uint64 |
| `Seq` | `U`, 1..18,446,744,073,709,551,615 |
| `Time` | `U`, 0..9,223,372,036,854,775,807 (`T`); UTC epoch milliseconds |
| `Attempt` | `U`, 1..65,535, additionally at most the job's stored max attempts |
| `ID` | Tag `07`, length exactly 16, not all zero; public form exactly 32 lowercase hex digits |
| `Key` | Tag `06`, 1..255 UTF-8 bytes, no U+0000; all other scalars allowed |
| `Diagnostic` | Exact map in §E; not arbitrary text/term |

Every Event has these **common required fields**:

| Key | Type/domain and meaning |
| --- | --- |
| `at` | `Time`; producer's captured wall time, never supplied by replay |
| `expected_revision` | `U`; 0 only for insertion, otherwise `Seq` matching the prior job revision |
| `job_id` | `ID`; identity within this STORE |

Let `S` be this Record's validated sequence. A non-insertion Event requires an
existing job and its exact previous revision `< S`; every accepted Event sets
revision to `S`. Cycle/execution tokens on disk are `Seq` coordinates within the
current immutable STORE_ID, not runtime references or the public generation token.
Replay checks no registry/module presence and no current clock. Wall times may
decrease across Events; only the explicit due-time checks below compare them.
The Event decoder checks encoding, exact keys, local domains and cross-field
relations decidable from this payload alone. Every rule referring to a previous
job, stored policy/state/token or S belongs to the shared pure transition layer;
the Event decoder does not accept or query job state. This distinction determines
`invalid_payload` versus `consumer_rejected` in §H.

### Type 1 / schema 1 — job_inserted

Exact keys: `at, definition, eligible_at, expected_revision, job_id`.

| Additional key | Exact domain |
| --- | --- |
| `definition` | Exact §C map |
| `eligible_at` | `Time`; equals `at` if definition's `scheduled_at` is nil, otherwise equals that stored requested time |

Job must be absent and expected revision 0. Set `available` if eligible_at ≤ at,
otherwise `scheduled`; attempt 0, next attempt 1, cycle token S, no execution
token/diagnostic. Preserve definition unchanged and inserted time `at`. Ready
order uses S when initially available. A duplicate insertion **record** is
invalid history, not reconciliation; same-ID reconciliation produces no record.

### Type 2 / schema 1 — job_available

Exact keys: `at, due_at, expected_revision, job_id`.

| Additional key | Exact domain |
| --- | --- |
| `due_at` | `Time`; exactly the current scheduled/retry due time, and ≤ `at` |

Only `scheduled/retryable` → `available`. Preserve attempt, next attempt and
cycle; eligibility remains this due time; available-order coordinate becomes S.

### Type 3 / schema 1 — job_started

Exact keys: `at, attempt, cycle_token, expected_revision, job_id`.

| Additional key | Exact domain |
| --- | --- |
| `attempt` | `Attempt`; exactly stored next attempt |
| `cycle_token` | `Seq`; exactly current cycle token |

Only `available` → `executing`, with `at` ≥ current eligibility. Set attempt to
the supplied ordinal, active execution token S and attempted time `at`; retain
cycle. Consume ready eligibility. Runtime claim/old-task fencing remains R4;
neither worker configuration nor process existence is a replay precondition.

### Type 4 / schema 1 — job_finished

Exact keys: `at, diagnostic, disposition, execution_token, expected_revision,
job_id, next_attempt, next_due_at, outcome`.

| Additional key | Exact domain |
| --- | --- |
| `diagnostic` | Nil for success; otherwise non-nil §E map with code allowed below |
| `disposition` | `U`: 0 completed, 1 retryable, 2 discarded; no other values |
| `execution_token` | `Seq`; exactly current active start's sequence |
| `next_attempt` | `Attempt` for retryable; nil for completed/discarded |
| `next_due_at` | `Time` for retryable, satisfying §D; nil for completed/discarded |
| `outcome` | `U`: 0 success, 1 worker_failure, 2 timeout, 3 interrupted; no other values |

Prior state MUST be `executing`. Let N be current attempt and M stored max attempts:

| Outcome | Diagnostic code | Only legal disposition / next attempt |
| --- | --- | --- |
| 0 success | nil diagnostic | completed / nil |
| 1 worker_failure | 1, 2, 3, 4 or 6 | retryable / N+1 if N < M; otherwise discarded / nil |
| 2 timeout | 5 | retryable / N+1 if N < M; otherwise discarded / nil |
| 3 interrupted | 7 | retryable / **N**, including N = M |

All inconsistent combinations are invalid, even with correct CRCs. Atomically
set the disposition state and its next attempt/due, clear active execution, and
retain last-started logical ordinal N. Completion sets completed time `at`.
Non-nil diagnostic replaces the latest diagnostic; success retains any prior
diagnostic. No separate failure or retry-schedule Event is permitted.

### Type 5 / schema 1 — job_cancelled

Exact keys: `at, execution_token, expected_revision, job_id`.

| Additional key | Exact domain |
| --- | --- |
| `execution_token` | Exact current `Seq` if executing; nil otherwise |

Only `available/scheduled/retryable/executing` → `cancelled`. Clear active
execution, next attempt and current due eligibility; preserve attempts/cycle,
definition and latest diagnostic. This durable transition fences later starts
and outcomes. Already-cancelled API reconciliation writes nothing: a second
cancellation record is invalid history. Completed/discarded are invalid sources.

### Type 6 / schema 1 — job_retried

Exact keys: `at, expected_revision, job_id, mode, new_due_at`.

| Additional key | Exact domain |
| --- | --- |
| `mode` | `U`: 0 expedite, 1 new_cycle; no other values |
| `new_due_at` | `Time`; exactly `at` (manual retry means immediate eligibility) |

Mode 0 requires `retryable`: preserve attempt/next attempt/cycle. Mode 1 requires
`discarded`: set attempt 0, next attempt 1, cycle S; clear prior attempted and
completed timestamps. Both set `available`, eligibility `at`, available-order
coordinate S and no active execution. Preserve immutable definition and latest
diagnostic. All other sources/modes are invalid. No physical token is reused.

All job facts not explicitly changed above are retained. Scheduled/retryable
states have a due time; executing has its active token; terminal states have no
next attempt/due/active token. Runtime rendering fields are not a second schema.

## C. Immutable job definition

Exact map keys (sorted): `args, definition_version, max_attempts, queue_key,
retry_policy, scheduled_at, timeout_ms, worker_key`.

| Key | Exact domain / construction default |
| --- | --- |
| `args` | §A args map; mandatory, no implicit persisted default |
| `definition_version` | `U`, exactly 1 |
| `max_attempts` | `U`, 1..65,535; builder default **10** |
| `queue_key` | `Key`; explicit trusted mapping, convenience default `"default"` |
| `retry_policy` | Exact map below; v1 is the builder default and only supported policy |
| `scheduled_at` | Nil for immediate, otherwise `Time`; builder default nil; past times allowed |
| `timeout_ms` | `U`, 1..86,400,000; builder default **30,000**; no infinity/zero |
| `worker_key` | `Key`; required stable key, no module-name-derived default |

Exact retry-policy map keys: `base_ms, cap_ms, jitter_divisor, version`.
All values use `U` and MUST equal **1000, 60000, 4, 1**, respectively. These are
v1 constants, not hidden operator overrides. A different policy needs the
compatibility review in §H. Builders materialize every default before submission.

Job ID is outside the definition: generate 16 CSPRNG bytes before submission,
redrawing the all-zero value; never derive it from a clock or sequence.
Original `scheduled_at` (including nil), not resolved insertion time or later
reschedule, participates in same-ID equality.
Compare the complete canonical definition bytes, including all versions/policy
values. Do not reconstruct it from mutable current job fields or new defaults.
Worker/queue text is never resolved during payload decode or pure replay.

## D. Retry policy v1 and arithmetic

For a retryable finish of logical attempt N, let:

```text
D = 60000                         if N >= 7
D = 1000 * 2^(N-1)                otherwise
Jmax = min(floor(D / 4), 60000 - D)
J = uniform integer in [0, Jmax]   (inclusive; 0 when Jmax = 0)
delay = D + J
next_due_at = min(T, at + delay)
```

Use unbiased rejection sampling from CSPRNG bytes for J; never modulo-biased
sampling, wall-clock seeds or replay-time randomness. No enormous exponent is
evaluated: branch at N = 7 first. Checked integer arithmetic/saturation occurs
before overflow; never wrap to an earlier timestamp. At T saturation can make
the effective delay zero; this is the explicit end-of-time-domain behavior.

Replay does not draw J or recompute a choice. It validates the stored due lies
in the inclusive interval `[min(T, at+D), min(T, at+D+Jmax)]`. Thus the persisted
due is the exact authoritative choice; no additional jitter field is necessary.
This same delay rule applies to infrastructure interruptions using **N**, not
N+1, while their next ordinal remains N. Manual expedite/new-cycle uses §B,
not this backoff rule. Samples: N=1 permits 1000..1250 ms; N=6 permits
32000..40000 ms; N≥7 permits exactly 60000 ms.

`max_attempts` bounds settled worker failures/timeouts in each manual cycle,
not physical invocations. Interrupted runs do not consume that budget, even
at M; each new start has a new physical sequence token. Success is allowed on
any ordinal ≤ M. Default timeout is 30,000 ms, measured monotonically from
callback release; waiting for durable start is excluded. Timeout outcome code
and retry/discard decision are stored together, regardless of later task death.

## E. Diagnostic v1

Only the exact map `{"code": U, "version": U(1)}` is allowed. Its canonical
encoding is **exactly 44 bytes**, of which 11 are text-key body bytes. Nil is
one byte and is allowed only for success. No message, stack, class/module name,
user error term, worker result, byte blob or extra field is stored. This is a
deliberately code-only first-release diagnostic, not a durable exception report.

| Code | Meaning / producer classification |
| --- | --- |
| 1 | Worker returned `{:error, reason}`; reason discarded |
| 2 | Worker raised an exception; no Exception/Inspect callback invoked |
| 3 | Worker threw a term; term discarded |
| 4 | Observed worker exit/death, excluding Tay infrastructure-generation loss |
| 5 | Tay's stored execution timeout expired |
| 6 | Worker returned anything outside `:ok`, `{:ok, term}`, `{:error, term}` |
| 7 | Infrastructure-interrupted execution reconciled after full recovery/activation |

`:ok` or `{:ok, term}` is success and term is discarded. No coercion of strings
or other “truthy” results to success. Trusted relays normalize these codes before
Engine admission; raw worker terms never become Event data or default logs.
Only the latest non-nil diagnostic is retained in the disposable job view;
earlier ones remain in history. No configurable larger diagnostic body exists in v1.

## F. Resource limits versus insertion limits

These budgets are **operational**, never persisted validity rules. Raising a
budget permits a new read/replay attempt on unchanged bytes. A budget failure
uses `{:error, {:resource_limit, fixed_internal_key}}`, not `:invalid_payload`,
`:consumer_rejected`, truncation or partial success. Physical/schema violations
remain invalid regardless of a larger budget.

| Existing recovery option | Exact unchanged default / accepted domain |
| --- | --- |
| `max_decode_payload_bytes` | 16,777,216; integer 0..16,777,216 |
| `event_limits.depth` | 64; positive integer |
| `event_limits.output_nodes` | 100,000; positive integer |
| `event_limits.binary_bytes` | 16,777,216; nonnegative integer; counts §A text **and** opaque bytes |
| `max_directory_entries` | 100,000; positive uint32 |
| `max_total_segment_bytes` | `:infinity`; or positive integer |
| `max_replay_records` | `:infinity`; or nonnegative integer |
| `deadline_ms`, `activation_deadline_ms` | 900,000 each; positive milliseconds |
| `activation_window_ms` | 30,000; positive milliseconds |
| `io_timeout_ms` | 10,000; positive milliseconds, capped by phase deadline |

All Phase 3 deadline/activation uncertainty and native packet limits remain as
specified in [Phase 3 §15](phase-3-recovery-rfc.md#15-limits-concurrency-and-cancellation).
Parser budget keys are the fixed atoms `:depth`, `:output_nodes`, `:binary_bytes`;
never derive a key from disk text. Limit checks occur during decoding (§A), not
only after a large term has already been built. Candidate-state accounting and
generation admission remain R4, not new Event fields or exact-RSS claims.

New-insertion defaults, independently configurable in Engine options:

| Option | Exact default / configurable domain / counting |
| --- | --- |
| `max_insert_payload_bytes` | 1,048,576; integer 1..16,777,216; complete encoded Event payload, excluding Record overhead |
| `max_insert_args_bytes` | 262,144; integer 5..16,777,216; canonical encoded args map including all tags/lengths |
| `insert_value_depth` | 32; positive integer; entire Event, same depth definition as §A |
| `insert_value_nodes` | 10,000; positive integer; entire Event, same node definition as §A |

All applicable insertion limits must pass; no silent clamping. Small settings
may intentionally refuse every insertion. Bound/measure while walking input,
before a payload-sized output allocation or mailbox submission. These are not
limits for internal finish/cancel Events and do not reduce replay capability.
Same-ID comparison precedes **new-insertion** limits; separate finite decoding,
transport or candidate budgets may still refuse operationally, never claim a
conflict merely because a previously accepted definition exceeds new limits.
Engine configuration MUST require max insertion payload ≤ max decode payload
and ≤ replay binary_bytes, insertion depth ≤ replay depth, and insertion nodes
≤ replay output_nodes. Reject violations; do not silently raise replay budgets.
The payload-to-binary budget comparison is intentionally conservative. Every
live Event, including internal outcomes, also passes configured Event decode
budgets before append. Existing retained-state/admission checks still apply;
no promise that these per-Event checks alone bound full-store recovery memory.

## G. Literal conformance fixtures

Hex blocks/inline hex below are **literal bytes**; remove whitespace only.
SHA-256 hashes cover the decoded bytes, not Markdown/hex text. E1–E6 are
complete Record v1 frames, not Segment files. Their header CRC covers H[0:20];
record CRC covers H[0:20] concatenated with payload (header CRC excluded).
All use framing version 1, flags 0, schema 1. No existing fixture is changed.

### G1. Complete frames and one valid lifecycle

Use job ID `00000000000000000000000000000001`, worker `"w"`, queue `"q"`,
args `{}`, max attempts 2, requested schedule 10, timeout 30000 and the exact
§C policy/version. The valid **sequence order** is E1 → E2 → E3 → E4 → E6 → E5:
insert at 0; become available/start at 10; returned-error finish at 11 with J=0,
next ordinal 2/due 1011; expedite at 12; cancel the available job at 13.
Each event's expected revision is the previous event's sequence.

| ID | Type / sequence | Payload / frame bytes | Frame SHA-256 |
| --- | --- | --- | --- |
| E1 | 1 / 1 | 404 / 432 | `1b59a812f2b2129532a243c4586f5c8a7702ab99550e6593495715a0c111280e` |
| E2 | 2 / 2 | 104 / 132 | `54c6cac6d57c283e777c1d85621589f8234ec4d786766488b36d604ca67a6a06` |
| E3 | 3 / 3 | 130 / 158 | `d1097553e8e4201339b9fbab03425523d2e49b8f6d7e0d59b9596c3872b9540f` |
| E4 | 4 / 4 | 269 / 297 | `1884923c049b0500e4e61872b09285c68f1bbc715cd00448edbf8f6d0a1db73a` |
| E5 | 5 / 6 | 105 / 133 | `999d5dd5da12cb2b80070ea90fe60c8eec97112e1cffe8d236e5ef8da7f3d757` |
| E6 | 6 / 5 | 126 / 154 | `bb31c3ba2edb45900164723f1150d13b4418540387f04ad57b3732fcd04d0a5f` |

#### E1

```hex
5441590001010001000000000000000100000194027ac3040900000005060000
00026174040000000000000000060000000a646566696e6974696f6e09000000
0806000000046172677309000000000600000012646566696e6974696f6e5f76
657273696f6e040000000000000001060000000c6d61785f617474656d707473
040000000000000002060000000971756575655f6b6579060000000171060000
000c72657472795f706f6c69637909000000040600000007626173655f6d7304
00000000000003e806000000066361705f6d7304000000000000ea6006000000
0e6a69747465725f64697669736f720400000000000000040600000007766572
73696f6e040000000000000001060000000c7363686564756c65645f61740400
0000000000000a060000000a74696d656f75745f6d7304000000000000753006
0000000a776f726b65725f6b6579060000000177060000000b656c696769626c
655f617404000000000000000a060000001165787065637465645f7265766973
696f6e04000000000000000006000000066a6f625f6964070000001000000000
000000000000000000000001ba73b6ed
```

#### E2

```hex
54415900010200010000000000000002000000684f554c210900000004060000
0002617404000000000000000a06000000066475655f61740400000000000000
0a060000001165787065637465645f7265766973696f6e040000000000000001
06000000066a6f625f6964070000001000000000000000000000000000000001
dd8aeeb0
```

#### E3

```hex
544159000103000100000000000000030000008298185eae0900000005060000
0002617404000000000000000a0600000007617474656d707404000000000000
0001060000000b6379636c655f746f6b656e0400000000000000010600000011
65787065637465645f7265766973696f6e04000000000000000206000000066a
6f625f696407000000100000000000000000000000000000000183d4dcd7
```

#### E4

```hex
544159000104000100000000000000040000010dcc6d4a370900000009060000
0002617404000000000000000b060000000a646961676e6f7374696309000000
020600000004636f6465040000000000000001060000000776657273696f6e04
0000000000000001060000000b646973706f736974696f6e0400000000000000
01060000000f657865637574696f6e5f746f6b656e0400000000000000030600
00001165787065637465645f7265766973696f6e040000000000000003060000
00066a6f625f6964070000001000000000000000000000000000000001060000
000c6e6578745f617474656d7074040000000000000002060000000b6e657874
5f6475655f61740400000000000003f306000000076f7574636f6d6504000000
000000000180b926bf
```

#### E5

```hex
54415900010500010000000000000006000000696e3ff4640900000004060000
0002617404000000000000000d060000000f657865637574696f6e5f746f6b65
6e00060000001165787065637465645f7265766973696f6e0400000000000000
0506000000066a6f625f69640700000010000000000000000000000000000000
01a3d6cae8
```

#### E6

```hex
544159000106000100000000000000050000007e4a0be0170900000005060000
0002617404000000000000000c060000001165787065637465645f7265766973
696f6e04000000000000000406000000066a6f625f6964070000001000000000
00000000000000000000000106000000046d6f64650400000000000000000600
00000a6e65775f6475655f617404000000000000000ca54d5472
```

Budget counter oracle for E1 is depth **4**, nodes **35**, binary_bytes **185**.
With otherwise sufficient limits, exactly those three budgets succeed; lowering
any one by 1 fails operationally, without changing its physical/schema validity.

### G2. Value boundary vectors

These are standalone value-parser/exact-consumption vectors, not complete Event
payloads. V rows are valid values; X rows are invalid payload syntax. V23's
opaque value is not valid as args (and not a length-16 ID); V15's NUL is valid
args text but invalid in a worker/queue key. V16 and V17 remain different bytes.

| ID / meaning | Literal hex | SHA-256 |
| --- | --- | --- |
| V00 — nil | `00` | `6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d` |
| V01 — false | `01` | `4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a` |
| V02 — true | `02` | `dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986` |
| V03 — int64 minimum | `038000000000000000` | `b9b8f72be2eec31d908160bfcfc8b04e118eca731888b43b6b842c4267c1fc3c` |
| V04 — minus one | `03ffffffffffffffff` | `339eed010a5e07b4314cb00f1234d636dc30df8fce73917165c299c6b4811804` |
| V05 — uint zero | `040000000000000000` | `93e60f669b99ad3e3ee6284b139e57adfb419960f390858e46ea565bbf82d001` |
| V06 — signed-positive maximum as uint | `047fffffffffffffff` | `9a6d8f59e9688e6298a6457011969ca598f6bd3e154a746c22a299fca5a87a5e` |
| V07 — 2^63 as uint | `048000000000000000` | `15c9b5d13d99e2afce728fca9de0850dd4cfe63a5318ac6cd9ff94b1dca87ff7` |
| V08 — uint64 maximum | `04ffffffffffffffff` | `0806653bb73f9922b047d694edd1750c506c086957c9ee0608ddd1856d207de5` |
| V09 — float positive zero | `050000000000000000` | `6c449f91c1adbf3945ad078f5f875c0c1f133f246c4588668faffbe23a3c195f` |
| V10 — float negative zero | `058000000000000000` | `b7d0a547dfa7ddb4df0b4b3d5f5cd0f127273a9cc78246a6a595e9bca208701a` |
| V11 — float one | `053ff0000000000000` | `d85eec32b8bc9d775c7ebd03d8bcea24e38f2e5301c1bfc632357dede779e736` |
| V12 — smallest positive subnormal | `050000000000000001` | `a011061167419227d27191bcfecb53baee0b76a98334b8b65bcbf6b3fea28f6d` |
| V13 — largest finite positive float | `057fefffffffffffff` | `e81302fd36fc158d3d978ca808d262cfa7667c3e1784f59c9bdddac976a1ca05` |
| V14 — empty text | `0600000000` | `b45482224b439a3d548c65378929b7dcc16a42288530b7b20d5c8103cc879d10` |
| V15 — NUL text | `060000000100` | `06c4df6668e142864ca3ea31637eb5dbd76d36115399f581249648f8855acae2` |
| V16 — U+00E9 | `0600000002c3a9` | `28b0c37fcc9587b46c38e8da4f697dd3a6645df0f31bd9e0d87a11f3cae5663d` |
| V17 — e plus U+0301 | `060000000365cc81` | `e3675b08b81dcf18ccf60c614161a6436ae48a537bde9bd825b5a2af092f2167` |
| V18 — U+0407 | `0600000002d087` | `087317a4e64aab78e69e6bfff106d03969dba6ebc3cd425372fb02a9179a3ca9` |
| V19 — U+1F600 | `0600000004f09f9880` | `bdbd1b7f7d4b30925d7109e134d3a0666e68e8a341647ba19f808ea1fb42d17d` |
| V20 — U+10FFFF | `0600000004f48fbfbf` | `2d4e31303a612040d7976c45a1e46dee1b57b5028a2c66015021880bd0c9f41f` |
| V21 — empty list | `0800000000` | `18b1b592a44f7fbe33dab6a3d22857eea5118da14d6fabbc59b0681dbf1286f1` |
| V22 — empty map | `0900000000` | `ceba8e226fc1ae3ed6e6fd58d778d4365556868b78faf5e5abbab0c04e0bd392` |
| V23 — opaque one byte | `070000000100` | `d7a1109d4371820092ee5b393b6d03a58f7a099bb67c45e8b458c8189a299823` |
| V24 — map keys aa,b ordered by body, not length prefix | `0900000002060000000261610006000000016200` | `df2559a785501c923fbed9a412d4cd32828c46b3d361ad7a10cd507fd755a86f` |
| X01 — reject nonnegative signed tag | `030000000000000000` | `dc4c8669df128318c5790c414c870cc76c585268552851e78d3ee8604dbec0e3` |
| X02 — reject positive infinity | `057ff0000000000000` | `58201ed1c77965aa3f7598c5effa9c8d67aca7c5273c0d803ab01e9f2e3e5720` |
| X03 — reject quiet NaN | `057ff8000000000000` | `1e334b0078af795f8b546ca71463f6cac4e364f469acb490780e915e8deff861` |
| X04 — reject overlong UTF-8 NUL | `0600000002c080` | `6572a1f198cf80b8db5deb91f05e19ccea044782d3937518a3328594832f95a5` |
| X05 — reject surrogate U+D800 | `0600000003eda080` | `65defe900139cee0857930a1124488394cc54a711692ed11c5ff4858cc73a55a` |
| X06 — reject above U+10FFFF | `0600000004f4908080` | `6bd86c80a0f9334c97302f1b6b503d9a2e9231ee5a436ff5c5aa2f3675e10b6f` |
| X07 — reject truncated UTF-8 scalar | `0600000001c3` | `1863998c3f504c7a056a637d44f28865733bfcf2a228004895a47f1d4e592b98` |
| X08 — reject lone continuation | `060000000180` | `bab55a4d73a9a687335c193cf1fbf33331b4a15c89214b0d0c5a3ab0aece7f4e` |
| X09 — reject truncated unsigned body | `0400` | `c0ba8a33ac67f44abff5984dfbb6f56c46b880ac2b86e1f23e7fa9c402c53ae7` |
| X10 — reject truncated text body | `060000000261` | `865566bb05a165ddedd5df5f4b86ef694a243022387d6af35d39a1dfe6e7421b` |
| X11 — reject non-text map key | `09000000010000` | `1d96f47b3a65ac17196e57f3bb919a35701c7fda77c67a5021c2c822d11eec99` |

### G3. Negative vectors

N1–N4 exercise generic value parsing/exact consumption, before Event field
validation. N5/N6 are complete type-5/schema-1 **payloads**, not frames.
N7 is a complete physically valid type-3/schema-1 **frame** with sequence 3;
after E1/E2 it must fail transition validation, not CRC validation. N8 is a
complete type-4/schema-1 **payload** with an intrinsically inconsistent outcome.

| ID | Required classification | SHA-256 |
| --- | --- | --- |
| N1 — duplicate map key a | `invalid_payload` | `26f3545dc521d5ba729bf92b4481b556328c0b8f72e2e78db4e40c49a39b6322` |
| N2 — unsorted map keys b,a | `invalid_payload` | `b859ceb3992994625036a8c8a9fa4fe360b915763290d153eece1748085057aa` |
| N3 — trailing nil after empty map | `invalid_payload` | `de2aeb86de0b0d8ab2d688da5642fa03c5e8c4402a5fd21543718d6cb8b4097d` |
| N4 — unknown value tag | `invalid_payload` | `01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b` |
| N5 — missing execution_token | `invalid_payload` | `9fa25a51b7ae4c7d0f299364438645d966dea307198298e798cfecd998fccd74` |
| N6 — extra x field | `invalid_payload` | `e0f9b1bf36631eed069470ff227586a246e81ed58f94f909d908fafade719de6` |
| N7 — attempt 2 instead of next attempt 1 after E2 | `consumer_rejected` | `a75272200392f635206e5dddab74d0f92fcd216d44e70caea0982f06a28ca26f` |
| N8 — success outcome with retryable disposition | `invalid_payload` | `7dd7f3353146649a5587303862d44c94f8425aa5536e439b7d72d0af2e4456b8` |

#### N1

```hex
09000000020600000001610006000000016100
```

#### N2

```hex
09000000020600000001620006000000016100
```

#### N3

```hex
090000000000
```

#### N4

```hex
0a
```

#### N5

```hex
09000000030600000002617404000000000000000d0600000011657870656374
65645f7265766973696f6e04000000000000000506000000066a6f625f696407
0000001000000000000000000000000000000001
```

#### N6

```hex
09000000050600000002617404000000000000000d060000000f657865637574
696f6e5f746f6b656e00060000001165787065637465645f7265766973696f6e
04000000000000000506000000066a6f625f6964070000001000000000000000
00000000000000000106000000017800
```

#### N7

```hex
544159000103000100000000000000030000008298185eae0900000005060000
0002617404000000000000000a0600000007617474656d707404000000000000
0002060000000b6379636c655f746f6b656e0400000000000000010600000011
65787065637465645f7265766973696f6e04000000000000000206000000066a
6f625f6964070000001000000000000000000000000000000001454299ec
```

#### N8

```hex
09000000090600000002617404000000000000000b060000000a646961676e6f
7374696309000000020600000004636f64650400000000000000010600000007
76657273696f6e040000000000000001060000000b646973706f736974696f6e
040000000000000001060000000f657865637574696f6e5f746f6b656e040000
000000000003060000001165787065637465645f7265766973696f6e04000000
000000000306000000066a6f625f696407000000100000000000000000000000
0000000001060000000c6e6578745f617474656d707404000000000000000206
0000000b6e6578745f6475655f61740400000000000003f306000000076f7574
636f6d65040000000000000000
```

### G4. Calculation and verification evidence

These document vectors were calculated without invoking Tay's Record/Event
encoder. An ephemeral JavaScript big-endian serializer plus reflected
`0x82f63b78` CRC calculation and a separately written Ruby serializer plus
normal `0x1edc6f41` CRC with explicit input/output reflection produced identical
payloads and full frames for all six Events. Both CRC paths passed the
`123456789 → e3069283` check. Ruby's standard Digest SHA-256 calculated the
listed hashes. Neither calculator was added as source, tests or fixtures.
An additional read-back audit of this Markdown verified all 50 literal/hash
pairs, scalar/UTF-8 acceptance and rejection, exact Event field mutations,
resource counters, the six-record lifecycle and bounded/saturating retry math.
Normal-polynomial CRC revalidation passed for all seven complete document
frames, including the intentionally transition-invalid N7.

Before implementation acceptance, import these literals unchanged into the
approved fixture location and test every field/domain and transition branch,
including success/discard/interrupted-at-M and executing cancellation. The six
positive examples are a minimum fixed corpus, not exhaustive transition coverage.

## H. Compatibility

- Explicit production capability set is `{(1,1),(2,1),(3,1),(4,1),(5,1),(6,1)}`.
  `known_type?/1` is true exactly for 1..6; `supported_schema?/2` is true exactly
  for those six pairs. No `schema <= latest`, disk-discovered registry or raw fallback.
- Record accepts all physically assignable values exactly as before. After full
  physical preflight/continuity, unknown Event type or unsupported per-type
  schema stops recovery with `:unsupported_semantics`, preserving all storage
  bytes/namespace, no partial projection and no activation/successor. Never skip.
  Physical type 0/255 or schema 0 remains a structural error, not an Event lookup.
- Malformed known payload → `:invalid_payload`; legal fields in an impossible
  transition → `:consumer_rejected`; insufficient operational budget →
  `:resource_limit`. Unknown nested policy/definition/diagnostic version is an
  invalid domain in this known schema, not a module-loading opportunity.
- **Schema 1 is immutable forever**, including tags, domains, required keys,
  enum meanings, policy math and diagnostic shape. Do not extend it with an
  “optional” field, new enum value, policy version or previously illegal value.
  Add a reviewed new per-type schema ID and explicit decoder/transition support.
  A new Event meaning receives a never-reused type number. No semantic schema
  change requires changing Record/Segment/STORE v1 by itself.
  A future policy change must version every affected downstream Event contract,
  not merely add a new policy number to insertion and reinterpret schema-1 finishes.
- Mixed historical schemas require explicit support for every encountered pair
  and a shared domain transition contract; old records/fixtures are not rewritten.
  Deploy readers before enabling new writers only through a separately reviewed
  rollout; rollback to an incapable reader must refuse, not discard newer Events.
- No redefinition based on runtime struct layout, worker registry, code defaults
  or current atoms/modules. No implicit migration of Phase 1–3 test-provider
  stores; their fixtures/providers remain untouched. Keep all new literal vectors
  fixed after approval; fix an implementation to match them, not vice versa.

## I. Remaining decision / approval boundary

R2 and the concrete R3 constants have no unspecified tags, keys, enums, policy
values or diagnostic/decoder domains left in this appendix. **No further R2/R3
design decision blocks Phase 4 once this appendix is approved.** R1/R3/R4 are
already approved. R5's measured production envelope remains a Phase 6 release
gate, not a prerequisite to Phase 4 implementation.

Approval of this appendix and explicit Phase 4 implementation authorization are
still required. This artifact creates no codec, tests, production fixtures or
allocation in running Tay. Stop here; do not begin Phase 4.
