# Qualification benchmark harness

Run in a dedicated VM, on disposable synthetic stores. Every `--path` must be
absolute and **not exist**; the harness never overwrites a store, removes history,
or deletes its output. `--output` also uses exclusive creation. Preserve the JSON
and generated store for review. Do not run against production data.

This is a measurement tool, not a durability mode, a production capacity claim,
or an R5 approval. It uses real public job APIs, the actual Event/Record codec,
normal Writer barriers and a bounded trusted worker. No synthetic Engine state,
fake clock, disabled execution, lowered rotation threshold or cached physical
validation is used. `replay` alone builds offline topology fixtures through the
existing Writer, with legal Events and explicit normal rotations.

## Commands

Development smoke on macOS (development `:write`, never strict durability):

```sh
mix run --no-start bench/run.exs --scenario lifecycle --mode write \
  --path /private/tmp/tay-bench-lifecycle-new --jobs 100 --args-bytes 1024 --clients 8 \
  --output /private/tmp/tay-bench-lifecycle-new.json
```

For Linux production-build measurements, first validate a **local** filesystem
and its deployment assumptions independently. A `stat` type alone does not prove
honest barriers, safe storage hardware or power-loss behavior. Use a fresh child
of the already-validated volume; never enable the assertion on overlay/network
storage merely to make a benchmark pass:

```sh
stat -f -c %T /validated/local/bench
MIX_ENV=prod mix run --no-start bench/run.exs --scenario lifecycle --mode sync \
  --validated-filesystem --path /validated/local/bench/lifecycle-new \
  --jobs 100 --args-bytes 1024 --clients 8 \
  --output /validated/local/bench/lifecycle-new.json
```

Repeat the same command with these scenario-specific arguments, a new path and
a new output for each run:

| Scenario | Arguments | Measures |
| --- | --- | --- |
| `lifecycle` | `--jobs 100 --args-bytes 1024 --clients 8` | Insert ACK RTT, start/finish Writer receipts, callback delay, queue service counts, bytes/job, private ETS bytes and cold restart |
| `schedule` | `--jobs 20 --args-bytes 1024 --clients 8` | Idle and insertion-load due-time lag overall/per queue; actual in-flight client-call overlap; counted known client-slot refusals |
| `rotation` | `--rotation-segments 2` | Organic minimum-target rotation using actual insertions, 262,000-byte text body plus realistic bounded args metadata; threshold remains 16,777,352 bytes |
| `replay` | `--replay-segments 1,10,100 --args-bytes 1024` | Full real Engine recovery and sampled memory for **compact manually rotated** histories, one job per segment |
| `reserve` | no additional required arguments | Real pre-I/O 3,000-byte history-budget refusal while a live callback holds its outcome reserve; actual finish still commits |

Run larger lifecycle cohorts explicitly to determine the tested retained-job
envelope. The Engine uses its ordinary 64 client permits unless `--client-slots`
is supplied separately; `--clients` counts offered concurrent benchmark callers.
The captured status/configuration always reports both. Keep some spare permits
for delayed completion reclamation when measuring successful insertion latency;
permit-bound refusal is measured separately by insertion load/admission tests.
`jobs` is bounded at 100,000, `clients` at 64, and configured arg body at
262,000 bytes; these harness bounds are not capacity guarantees. `schedule` uses
at most 20 probes per group and at most 10,000 load requests. Each known pre-I/O
client-slot refusal is counted and not retried; a new load request has its own ID.
Unknown outcomes and other errors stop the run. Saturation is labelled proven
only if at least the configured client count has observed insertion calls
overlapping the probes' captured due instant. Otherwise the output explicitly
reports insertion-load lag without claiming saturated qualification.

All probes alternate two configured queues, two workers per queue. The callbacks
are a bounded no-op external effect recorded in a separate observer; they do not
measure application-specific work or exactly-once side effects. The reserve
scenario alone holds one trusted callback for at most 60 seconds awaiting its
controller. No extra production worker or public API is introduced.

## Measurement interpretation

- JSON `report_schema: 1` includes OS, Elixir/OTP, scheduler count, word size,
  filesystem evidence, durability mode, options and UTC run time. `null` means
  no samples, not zero latency. Percentiles are nearest rank; always report the
  sample count. A single rotation cannot establish a p99 latency guarantee.
- Local tracing captures only function arities and bounded Event type/16-byte-ID
  context. No payload, args, result or full Engine state is emitted. Tracing is
  process-scoped to the measured Engine/Writer, but installs VM-wide function
  patterns: use a dedicated VM without another tracer. It adds timing overhead.
- Append latency ends at the actual Writer receipt and includes that mode's
  write/sync behavior. It excludes subsequent projection/reply. Start-receipt to
  callback entry and callback return to finish-receipt are separate intervals.
  Insert RTT covers the public call and its successful acknowledgement.
- Indexed job/queue/scheduler function counts are recorded. Reader calls during
  live tracing expose disclosed rotation validation scans. Fresh recovery itself
  also fully traverses history; read/index tracing is not a claim that recovery
  or rotation avoids physical scans. No scan optimization is made here.
- Memory uses 5 ms sampling and records bounded maxima, not a sample history.
  Engine/Writer process heaps, VM binary/ETS/total memory, a pre-restart baseline,
  post-activation private ETS byte metadata and semantic state/definition charges
  are separate observations. Short candidate peaks may be missed, shared binary
  backing is not process heap, and allocator/observer costs affect VM totals.
  These figures do not prove an exact RSS upper bound or required free RAM.
- Compact 1/10/100-segment cases measure topology overhead, **not** filled-segment
  throughput or a 100-full-segment capacity envelope. Organic rotation separately
  reports its actual canonical byte and segment count. Every canonical byte
  total is reconciled against the Engine's incremental counter outside timed
  insert calls; no benchmark adds a per-insert history scan.
- Public status is an asynchronous bounded snapshot. At quiescent measurement
  boundaries the harness waits for it to reflect acknowledged Engine counters,
  rather than mistaking stale snapshots for durable state.
- `--deadline-ms` defaults to the unchanged 900,000 ms recovery and activation
  defaults. Output reports elapsed restart time and deadline comparison. Raising
  it must be explicit and reported; a run outside the approved deployment deadline
  cannot qualify that deployment profile. Owner-release retries are separately
  counted and included in startup time.

Focused harness checks, intentionally without organic large rotation:

```sh
mix test test/tay/qualification/benchmark_test.exs --warnings-as-errors
```

The final qualification report must retain exact commands, outputs, physical
fixture hashes and platform evidence. Publish only measured envelopes and leave
R5, hardware certification, actual workload RAM/disk headroom and unmeasured
profiles explicit. See [compatibility and limits](../docs/compatibility.md).
