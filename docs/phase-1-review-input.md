# Accepted adversarial review input for the future Phase 1 RFC

Status: accepted requirements and review findings, preserved during Phase 0.
This is not a Phase 1 RFC or an approved disk-format design. No layout, checksum
algorithm, payload encoding, repair procedure, or durability policy is selected
here. The user approved preserving this input while implementing Phase 0 only.

The subsequently supplied [record/segment candidates](storage-rfc-input.md)
record the user's framing, CRC32C, sequence, and segment-envelope directions.
Those candidates still require RFC review before implementation; the findings
below remain review input for that work.

These requirements supplement [TAY_PLAN.md](../TAY_PLAN.md). In particular, fixed
compatibility fixtures must start in Phase 1 rather than wait until Phase 10.

## Required constraints

1. Parser classification must be separate from recovery repair authorization.
2. An `incomplete` parse result alone never authorizes truncation.
3. Corrupted framing metadata, especially payload length, must not allow valid
   later records to be silently discarded.
4. Unknown semantic record types or unsupported schema versions must stop
   recovery rather than be skipped.
5. Format hard limits must be distinct from configurable insertion limits.
6. Checksum coverage must include every framing field whose corruption could
   alter interpretation.
7. Decoder stream-consumption semantics must be explicit.
8. Fixed compatibility fixtures should begin in Phase 1, not wait until Phase 10.
9. Persisted payloads must not depend on the current `%Tay.Job{}` layout or the
   presence of runtime atoms/modules.
10. ETF is not approved yet as the durable payload encoding.
11. Phase 2 must separately define file/directory sync and segment-creation
    durability semantics.

## Scenarios retained from the review

- A corrupted payload length in record B of `[A][B][C]` can falsely suggest an
  incomplete tail even though C is valid. Repair must not silently discard B
  and C. A trailing checksum may be unreachable if its position depends on the
  corrupted length.
- A parser cannot infer the history of damage solely from an incomplete byte
  sequence. An interrupted append and damage to an acknowledged record may
  leave identical bytes. Removing complete final records may leave a valid
  shorter log. The future RFC must state its failure assumptions and detection
  limits instead of treating parse results as permission to repair.
- Skipping an unknown cancellation/completion event can make a job runnable
  again. The RFC needs explicit semantic-version and unknown-event behavior,
  including downgrade behavior without modifying storage.
- If ETF is considered, a same-VM round trip can hide dependencies on existing
  atoms. Fresh-VM decoding and absent/renamed workers must be considered. Safe
  decoding does not replace application schema validation. Runtime-only terms
  and trailing bytes inside serialized payloads need explicit treatment.
- Lowering an insertion limit must not turn a valid historical record into a
  reason to truncate storage. Decoding resource limits, compressed expansion,
  and nesting limits need explicit treatment. No compression choice is made.
- Checksums must account for interpretation-changing metadata. Decoding a frame
  must not silently consume or discard later frames. Searching ahead for magic
  bytes must not conceal corruption. The subsequent candidate specifies CRC32C
  and big-endian integers; exact parameters and canonical checksum inputs still
  require the RFC review.
- Round-trip tests alone allow an encoder and decoder to drift together. Fixed,
  independently checked byte fixtures must anchor the approved format. The RFC
  must distinguish historical decoding compatibility from identical re-encoding
  across runtime versions.
- A valid checksum is not proof of durability. Creation and rotation can
  involve file and directory persistence requirements; Phase 2 must specify
  these separately for supported platforms.

## Verification input for later phases

The future test matrix must address metadata mutations with valid following
records, truncation boundaries, partial headers with invalid bytes, active versus
sealed tails, unsupported semantic versions/types, explicit stream consumption,
fixed historical fixtures, changed insertion limits, and payload-decoding
independence from the current runtime. Parsing tests belong to the codec phase;
repair authorization and filesystem behavior require their later components.

References supporting the accepted review:

- [OTP binary decoding and the safe/used options](https://www.erlang.org/doc/apps/erts/erlang.html#binary_to_term/2)
- [OTP encoding compatibility and deterministic encoding](https://www.erlang.org/doc/apps/erts/erlang.html#term_to_binary/2)
- [ETF compressed representation](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html)
- [Linux file and directory synchronization](https://man7.org/linux/man-pages/man2/fsync.2.html)

Implementation of Phase 0 does not resolve any of these future decisions.
