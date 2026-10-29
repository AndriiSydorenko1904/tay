# Qualification benchmark harness

For an isolated comparison of native CRC32C against the original Elixir
implementation, run `mix run --no-start bench/crc32c.exs`. It checks matching
checksums and reports median throughput for buffers from 20 bytes to 16 MiB,
including both sides of the 4096-byte dirty-scheduler threshold. These figures
measure checksum work only, not completed-job throughput.

`mix run --no-start bench/record_crc32c.exs` compares the previous two-NIF-call
record checksums against the combined one-call operation, with a 20-byte record
header and payloads from zero bytes to 16 MiB. It includes the per-buffer
dirty-scheduler boundary and reports median time per record.

## One-command local profiles

For a quick local check, use the profile runner. It creates a unique disposable
store for every case and preserves the JSON reports, exact commands and stores:

```sh
./bench/run-profile.sh smoke
./bench/run-profile.sh load
./bench/run-profile.sh schedule
./bench/run-profile.sh recovery
./bench/run-profile.sh storage
```

`smoke` normally finishes quickly. The default `load` profile executes 20,000
jobs; `recovery` executes 50,000 jobs and then measures a cold restart. Override
the workload without editing the scripts:

```sh
TAY_BENCH_JOBS=100000 TAY_BENCH_CLIENTS=64 ./bench/run-profile.sh load
TAY_BENCH_RECOVERY_JOBS=100000 ./bench/run-profile.sh recovery
TAY_BENCH_ARGS_BYTES=65536 TAY_BENCH_JOBS=10000 ./bench/run-profile.sh load
```

Run all profiles and select an explicit result directory:

```sh
TAY_BENCH_OUTPUT_DIR=/private/tmp/tay-bench-full ./bench/run-profile.sh full
```

The default is development `write` durability, which is appropriate for local
macOS behavior checks but not storage qualification. Linux `sync` measurements
require an independently validated local filesystem and an explicit assertion:

```sh
TAY_BENCH_MODE=sync \
TAY_BENCH_VALIDATED_FILESYSTEM=1 \
TAY_BENCH_OUTPUT_DIR=/validated/local/tay-bench \
./bench/run-profile.sh full
```

Do not point `TAY_BENCH_OUTPUT_DIR` at production data. The runner refuses an
existing directory and never deletes generated stores automatically.

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
  or rotation avoids physical scans. The segment parser uses bounded 1 MB
  sequential read-ahead, while records larger than that retain their bounded
  direct-read path.
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

## Group commit comparison

On a validated Linux filesystem, run the same concurrent enqueue workload for
all supported comparison points. Each report includes throughput plus the
existing nearest-rank enqueue RTT `p50`, `p95`, and `p99` measurements:

```sh
for interval in 0 1 5 10 50 100 1000; do
  MIX_ENV=prod mix run --no-start bench/run.exs --scenario group_commit --mode sync \
    --validated-filesystem --path "/validated/local/group-${interval}" \
    --output "/validated/local/group-${interval}.json" --jobs 20000 --clients 64 \
    --group-commit-interval-ms "$interval"
done
```

Every path and output file must be new. Compare
`measurements.enqueues_per_second` and
`measurements.insert_roundtrip_us.{p50,p95,p99}` across the seven reports.

The final qualification report must retain exact commands, outputs, physical
fixture hashes and platform evidence. Publish only measured envelopes and leave
R5, hardware certification, actual workload RAM/disk headroom and unmeasured
profiles explicit. See [compatibility and limits](../docs/compatibility.md).


## Comparable release artifacts

`bench/release.exs` uses only public Tay APIs so the same script can measure a
candidate checkout and a previous release such as `v1.7.0`. Use a dedicated VM
and new disposable paths for each cohort:

```sh
mix compile --warnings-as-errors
mix run --no-start --no-compile bench/release.exs --mode write \
  --path /private/tmp/tay-release-candidate-new --output /private/tmp/candidate-new.json \
  --jobs 1000 --clients 8 --trials 3
# Compile the baseline in a separate process too, then run the SAME absolute
# script path with `mix run --no-start --no-compile` from that checkout,
# selecting another new path and baseline-new.json.
python3 bench/compare.py /private/tmp/baseline-new.json /private/tmp/candidate-new.json \
  --output /private/tmp/comparison-new.json --markdown /private/tmp/comparison-new.md
```

Run only the comparison with:

```sh
gh workflow run qualification.yml -f performance_only=true \
  -f baseline_ref=v1.7.0 -f performance_jobs=1000
```

The qualification workflow accepts `baseline_ref` and `performance_jobs` and
compiles each checkout in a separate process, then runs three trials per
checkout on the same macOS/Linux runner. This excludes compiler residue from
the measured runtime process. Linux uses a
disposable local Btrfs volume and explicit `sync` mode; macOS is labelled `write`
development evidence. JSON reports and a Markdown comparison are retained as
30-day artifacts, and the comparison is included in the workflow summary.
Artifacts contain benchmark metadata and measurements, not stores or user jobs.

Reports include the measured revision/version, dirty-tree marker, harness hash,
OS/toolchain/schedulers/filesystem, workload, completed-job throughput, enqueue
ACK p95, submission-to-callback p95, sampled RSS/BEAM memory and compaction time.
Throughput includes durable completion verification. Callback latency excludes
durable finish; RSS sampled every 50ms is an observed peak, not an upper bound.
There is no production capacity or power-loss claim.

Comparison refuses different harness/configuration/environment metadata and
incomplete trial cohorts. Missing/zero/invalid metric samples remain missing,
never an improvement. Median changes are descriptive by default. Enable
`fail_on_regression` in the workflow (or `--fail-on-regression`) to fail on a
regression beyond 20% or incomplete required metrics. Hosted-runner noise,
cache state and the absence of hardware certification still limit conclusions.
