# Compatibility and limits

Store v2 supports two schema-1 MANIFEST representations for the existing
`terminal_retention` key: the original `"infinity"` value and the canonical
one-key Value map `{"hours" => N}`, where `N` is in
`1..2_562_047_788_015`. Framing versions, keys, CRC32C, and CURRENT's manifest
digest are unchanged. Readers that predate bounded retention may fail closed on
the map representation; do not use an older binary to open an epoch published
with bounded retention. Unknown forms are never converted to infinity or
repaired. Store-v1 and released fixtures remain unchanged.

Tay v0.9.2 is a single-node public preview. Record v1, STORE v1, Segment v1,
and Event v1 are fixed compatibility contracts described in [storage](storage.md).
The committed record, segment, and Event literal fixtures are permanent test
anchors; they are not generated from the current encoder or parsed from public
documentation. A newer binary must read every older supported byte and
transition. An older binary must refuse an unsupported event pair or transition
without publishing partial state. Rollback is safe only if the old binary
understands **all** history written by the newer one.

Persisted worker and queue names are stable UTF-8 keys. Keep their trusted
mapping to compatible callbacks when application modules change. Removing a
mapping blocks affected jobs; it does not drop them. Immutable definitions
retain their original arguments, schedule, timeout, attempts, and retry policy.
Reusing an ID with different canonical definition bytes is a conflict;
resubmitting the same ID and definition reconciles it. A new Event field needs
an explicitly versioned schema and literal fixtures, never a silent addition
to schema 1. The local [executor protocol](protocol.md) adds no disk schema:
connection registrations, capacity, and successful return values are not
restart-durable, while job completion remains durable.

## Supported runtime and storage

- Build with Elixir 1.20, Erlang/OTP 29, and a C11 compiler. The consuming
  release must be built for its target OS/architecture and compatible ABI;
  releases are not cross-platform bundles.
- Strict `:sync` durability is Linux-only on an explicitly validated supported
  **local** filesystem with truthful file/directory sync, locking, and
  exclusive publication. The operator must set `validated_filesystem: true`;
  the flag and a filesystem-type check are not hardware power-loss proof.
- macOS supports explicit development `:write` only, without a power-loss
  claim. Windows, network/object storage, distributed store ownership, and
  unvalidated production filesystems are unsupported. Production builds do
  not silently downgrade to `:write`.
- External effects are at-least-once, not exactly-once. There is no live
  backup, automatic torn-tail repair, online compaction, durable
  successful-result backend, cron/interval scheduling, or multi-host executor
  protocol. The local Unix socket is a same-host trust boundary.

## Finite reference profile

The measured reference was Elixir 1.20.2 / OTP 29 on a validated local Linux
Btrfs test volume: 10,000 retained jobs with small encoded arguments, eight
offered callers, two queues with two credits each, 30,000 Events, and
19,385,044 canonical history bytes. This is a finite example, not a throughput,
recovery-time, arbitrary-device, or power-loss guarantee. Validate the actual
target and workload before deployment. The conservative public-preview policy
is:

| Boundary | Value |
| --- | ---: |
| Encoded new-job arguments / payload | 1,105 / 2,048 bytes |
| Retained jobs / charged state bytes / nodes | 10,000 / 80,000,000 / 1,000,000 |
| Canonical history / segment allowance | 19,390,000 bytes / 5 coordinates |
| Client admission | 64 permits and 67,108,864 reserved request bytes |
| Measured wake interval | 50 ms |

These values are explicit configuration policy, not source defaults or a
Cartesian combination of independent stress tests. The history ceiling is
only 4,956 bytes above the completed reference cohort before additional
retries and interruptions; it is not a sustainable unbounded workload. No
terminal job or ID was evicted in that historical reference workload. Current
bounded compaction can expire terminal jobs/IDs; see [operations](operations.md).
Monitor admission, free disk, backup space,
restart resources, and retained staging. A larger or different workload needs
new target-specific measurement, not deletion of individual segments.

## Upgrade and restore

Drain and stop the old Engine, make a complete [cold backup](operations.md),
then inspect unchanged history with the target binary and sufficient budgets.
Start a fresh generation; do not carry forward ETS indexes, mutation revisions,
or pending RPCs. A complete event is replayed even if its caller never saw the
acknowledgement. If an old binary cannot understand all written history, it
must refuse rollback. Restoring an older backup is an explicit recovery-point
decision: later acknowledged jobs may be absent and effects may repeat. There
is no anti-rollback watermark or proof that a selected backup is the newest.
