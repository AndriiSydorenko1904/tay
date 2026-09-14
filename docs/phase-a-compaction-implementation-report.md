# Store-v2 compaction Phase A implementation report

Status: pure representation/replay checkpoint complete; no authority publication.

## Approved format corrections

The original per-job `available_revision` could not order different jobs with
equal due times. Store v2 instead persists a global nonzero uint64
`availability_order` on each entry to `:available`. The pure reducer requires
the next allocator value, and snapshot planning renormalizes current available
jobs in QueueIndex order to `1..N`. It retains the TaskIndex order as well.
The number is storage-internal, not a public revision or physical sequence.

The original model also lacked a timestamp for cancelled and discarded jobs,
making bounded terminal retention impossible to evaluate. Store v2 stores
`terminal_at` in every snapshot: nil in nonterminal states, the accepted
terminal mutation's durable `at` in completed/cancelled/discarded states.
The decoder fails closed on inconsistent combinations. V1 migration must derive
this field from terminal Event-v1 replay before Phase B can publish authority.
Neither correction changes frozen Store-v1 bytes.

## Files and wire layout

* `lib/tay/storage/v2/codec.ex`: bounded exact Store-v2 payload schemas.
* `lib/tay/storage/v2/reducer.ex`: pure logical-revision replay, global
  availability allocation and terminal timestamp state.
* `lib/tay/storage/v2/snapshot.ex`: retention classification, canonical
  snapshot planning and equivalence oracle.
* `test/tay/storage/v2_phase_a_test.exs` and
  `test/tay/storage/v2_property_test.exs`: focused and generated-history tests.
* `test/fixtures/storage/v2/records.hex`: seven literal full Record-v1 frames,
  one `(7,1)` snapshot and six `(8,1)` mutation kinds. `README.md` describes
  the inventory.
* `docs/storage-compaction-rfc.md` records the two approved format corrections;
  this report records the Phase-A checkpoint. The complete later worktree
  inventory is in the Phase-B implementation report.

The `(7,1)` snapshot payload is `job_id[16] || logical_revision[8] ||
cycle_token[8] || execution_present[1] || execution_token[8 if present] ||
canonical Value map`. The exact Value map contains `definition`, `state`,
`attempt`, `next_attempt`, `eligible_at`, `availability_order`, `inserted_at`,
`attempted_at`, `completed_at`, `terminal_at`, and `diagnostic`. The new
`terminal_at` key appears in the literal snapshot frame as canonical nil.

The `(8,1)` mutation payload is `job_id[16] || kind[1] ||
expected_logical_revision[8] || new_logical_revision[8] || at[8] ||
canonical kind-specific Value map`. Inserted, available and retried maps
now include `availability_order`. The Record-v1 28-byte overhead and CRC32C
are unchanged. All scalar prefix integers are big-endian. No new atom is
created from input.

## Qualification checkpoint

On macOS, `mix format --check-formatted`, `mix compile --warnings-as-errors`,
and `mix test test/tay/storage/v2_phase_a_test.exs
test/tay/storage/v2_property_test.exs --warnings-as-errors` passed. The last
focused run used ExUnit seed `332219`: 14 passed, comprising 11 examples and
three StreamData properties with 80 generated cases each. One property checks
every frontier of generated retry/success histories and a second snapshot;
another varies equal-due immediate/scheduled jobs and post-snapshot insertion;
the third exercises admin retry, interrupted execution, stale cycle/execution
tokens, terminal timestamps and repeated snapshots.

The examples cover exact fixture re-encoding, malformed/trailing/unknown and
duplicate-map-key rejection, revision and execution-token continuity, cycle
fencing, interrupted retry, terminal timestamp invariants, duplicate and
overflow availability orders, and 1,000 equal-due jobs with reversed job IDs.
The latter includes scheduled availability, distinct logical revisions,
recovery, two compactions and a newly available post-compaction job.

No physical Store-v2 generation has been published. Disk amplification and
compaction pause are not meaningful for this pure checkpoint. Phase B still
requires native-owner publication, V1 migration, V2 recovery/post-snapshot
writing, crash and platform qualification, and a separate implementation
report. Phase C automatic policy has not begun.
