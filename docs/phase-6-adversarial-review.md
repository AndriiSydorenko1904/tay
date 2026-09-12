# Phase 6 independent adversarial review

Disposition: **code-level review passed after fixes**. This automated independent
review is not a human R5 deployment-profile approval, a publication decision or
hardware power-loss certification. Final executed qualification results are in
the [implementation report](phase-6-implementation-report.md).

Scope: integrated Engine controls/capacity, lifecycle driver and supervisor,
local-task lease retirement, offline diagnostics/Mix tasks, cold-copy publication
and restore, packaging/compiler/source allowlist, detached consumer, and the
external ACK/effect crash oracle. Review work was independent of the affected
implementation workstream, with the primary agent integrating fixes and evidence.

## Findings resolved before qualification

| Scenario | Risk | Implemented protection and regression |
| --- | --- | --- |
| New runtime/fence dies after ready but before the queued restart result is consumed | A liveness check of Engine/Writer alone could return restart success before a queued revocation | Final restart result verifies exact runtime and `LocalFence.live?`; tests queue the real driver result, kill runtime/fence while Guardian is suspended and require refusal despite surviving Engine/Writer |
| Accepted recovery deadline exceeds BEAM's single receive-timer domain | Public diagnostic caller could raise `timeout_value` instead of a bounded diagnosis | Preserve the absolute operational deadline and split only local receive waits; huge-deadline missing/existing-store tests preserve namespace and return bounded results |
| Administrative cancel/retry is queued after lifecycle drain ACK but before Guardian closes the group | A new append could race what was thought to be quiescent graceful stop | Engine sets an exact operation-token fence before the ACK; queued admin mutation is refused before I/O while that stop/restart remains active. A paused-Guardian ordering test proves unchanged bytes. Plain drain and expired/aborted lifecycle operations retain documented admin semantics |

None required new Event bytes, format/protocol changes, repair or a reinterpretation
of R1–R4/G1–G6. Historical tests and literal fixtures were not altered to pass.

## Additional adversarial checks

- Stop/drain cannot infer task death from supervisor death or released flock.
  Generation revocation closes registration, and replacement waits exact old
  process death plus local lease retirement. An orphan ledger is not erased.
- A separate one-slot operational permit remains available under saturated client
  drain permits. Timeout never creates a second shutdown/restart driver or resumes
  claims. Fresh activation does not inherit ETS, a mutation reference or an RPC.
- Active outcomes retain conservative frame/rotation and coordinate reserves.
  Exact immutable maxima are finish payload/frame 269/297 bytes and cancellation
  113/141; each 1,132-byte reservation exceeds either frame plus possible rotation.
  No per-insert history scan or retained-ID eviction computes/frees capacity.
- Activation-created successor header accounting correctly adjusts Writer's
  pre-activation total/count summary by 44 bytes/one segment and is not doubled
  on the next recovery.
- Existing-only diagnosis has no activation path or partial-candidate output.
  Unknown semantic pairs remain physically readable but stop replay untouched.
- Cold copy covers the whole safe inventory and external catalog; pins no-follow
  descriptors, rejects unsafe links/FIFOs/source aliases, bounds enumeration and
  file reads, and uses new-only publication with destination ownership held.
  Every copied file, directory and required ancestor is synced before strict
  copy success. Failures preserve all source/destination/staging evidence.
- Unsigned catalogs do not authenticate backups or prove latest history. Older
  backup RPO and duplicate external effects are operator decisions; no implicit
  repair, prefix selection or anti-rollback contract is claimed.
- Packaged production runtime contains no test providers, fault helper/API,
  source-checkout dependency or runtime native compilation. License/version and
  actual publication remain explicit unapproved release choices.
- The independent crash matrix uses real SIGKILL plus fsynced external ACK/effect
  evidence at 19 cross-layer boundaries; effects are never treated as fabricated
  completion acknowledgements.

No additional correctness/data-loss/frozen-compatibility blocker was found under
the documented cooperative ownership and trusted embedding model. Remaining
limitations are explicit: reduced operational caps can block post-activation
interruption reconciliation; ENOSPC/device failures remain unknown/fail-closed;
arbitrary unlinked children/remote effects are not locally fenced; non-preemptible
native workers can prevent proven death; retained history grows; no live backup,
repair, snapshots or compaction exists. Measurements and final platform results
must support any R5 profile claim independently of this code review.
