# Compatibility and upgrade policy

## Immutable storage contracts

Record v1, STORE v1 and Segment v1 remain exactly the frozen Phase 1–3 formats.
The physical Record codec validates framing, assigned-versus-reserved numeric
domains, hard lengths and CRC32C; it does not consult Event capabilities.
Assignable unknown type `1..254` / schema `1..255` pairs are physically readable.
Reserved type 0/255 or schema 0 are structural errors. Physical readability is
not semantic replay support and never grants repair authorization.

Event v1 supports exactly `(type, schema)` pairs `(1,1)` through `(6,1)`:
inserted, available, started, finished, cancelled and retried. Capability checks
require exact membership, never `schema <= latest`. Schema 1 is immutable forever,
including exact fields, tags, enum meanings, retry math, canonical encoding,
consumption rules and fixed limits. There are no optional newly added schema-1
fields, fallback decoders, ETF, raw-byte semantics or `%Tay.Job{}` serialization.
The [approved Event appendix](event-v1-contract-appendix.md) remains authoritative.

Unknown event type/schema, invalid canonical payload, invalid state transition or
sequence continuity failure stops replay and leaves inspection storage untouched.
No event is skipped; no partial candidate is published or used to activate a
Writer. Full physical and semantic preflight precedes highest-sealed successor
creation. An older binary must refuse newer unsupported semantics rather than
pretend a physically intact history is understood.

## Evolving application code

Persisted worker and queue identities are stable inert UTF-8 keys. Keep the mapping
from each existing worker key to the intended compatible callback implementation
explicit in trusted configuration. Renaming a module without changing that key
does not change durable identity. Missing or unavailable mappings preserve jobs
and block dispatch; they never create atoms, resolve persisted module names or
drop state. Mapping restoration requires a fresh configured generation/index build.

Immutable definitions retain original args, schedule, max attempts, timeout and
retry policy. Changing worker builder defaults affects only new definitions.
Reusing a Job ID with different canonical definition bytes produces `id_conflict`,
including numeric representation differences. Same-ID/same-definition insertion
reconciles without a second insertion event. Keep the original intent when
handling an unknown outcome; generating a new ID can create duplicate work.

Opaque mutation revisions include STORE, job, generation and persisted revision.
After restart, capture the new revision deliberately before a new cancel/retry
decision. Do not replay pending RPCs or refresh an unknown-outcome mutation token
automatically. A complete event participates in replay regardless of prior ACK
visibility. Infrastructure-interrupted executions reuse the attempt ordinal with
a fresh physical token; this is not exactly-once execution or external fencing.

## Upgrade and rollback procedure

1. Check the target binary's explicit physical and semantic capability set, runtime
   versions and supported platform/profile; verify fixed fixture hashes unchanged.
2. Stop new admission, drain and explicitly stop the old generation. Do not hot
   replace semantic decoder code during replay or keep an old ETS projection.
3. Make and qualify a complete cold backup using the documented sync procedure.
4. Perform existing-only full inspection with the target binary and sufficient
   operational replay budgets. Inspection does not authorize later activation
   without a fresh continuous ownership session.
5. Start a fresh generation and validate bounded status plus application-level
   effects/ACK reconciliation. Retain the backup and failed evidence.

A future event field requires a separately specified schema (or type where
appropriate), explicit capability registration, exact semantics and independent
literal fixtures. Additions must preserve all historical schemas/fixtures and
include replay/downgrade tests; no future format is introduced in Phase 6.
Rollback is permitted only when the old code understands **every** pair and
transition already present. Otherwise rollback must fail closed. Restoring an
older backup is an explicit RPO/data-loss decision, not a transparent downgrade.
There is no anti-rollback watermark or proof that a chosen backup is latest.

## Fixtures and qualification scope

The original physical binary fixtures and all 50 approved Event literal/hash
vectors are permanent compatibility evidence, not regenerated encoder snapshots.
The implementation report records byte-identical comparisons, exact verification
commands, ordinary/property/fault tests, consuming-release checks and platform
results. Golden vectors supplement, rather than replace, independent parser,
transition and live-versus-replay tests.

Operational budgets (insertion, candidate memory, admission, canonical history,
directory traversal and deadlines) never redefine physical validity. A resource
limit diagnosis may be retried with a larger budget. It must not be mislabelled
corruption or used to skip/truncate history. Development write-mode evidence is
not a production acknowledged-durability proof. Validated Linux/Btrfs tests do not
automatically qualify all Linux filesystems, devices, containers or power failures.

No live migration, snapshot, manifest, compaction, automatic repair, distributed
execution or exactly-once external-effect contract is added by this release.
See [operations](operations.md), [packaging](packaging.md) and the measured
[production limits](production-limits.md) for operational and release gates.
