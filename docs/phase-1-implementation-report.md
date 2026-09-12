# Phase 1 implementation report

Phase 1 implements the approved physical record codec only. All final quality
gates pass on Elixir 1.20.2 / Erlang/OTP 29. No Segment, Writer, Reader, recovery,
Event serialization, sequence allocator, or Phase 2 design was introduced.

## Implementation and compatibility

`Tay.Storage.Record` provides `encode/1`, `decode/1`, and `decode/2`. The latter
accepts only the decoder resource budget. The approved 24-byte header, 28-byte
overhead, byte order, CRC coverage, validation precedence, and 16 MiB hard bound
are unchanged. Assignable types/schemas are physically accepted without a registry.

`Tay.Storage.CRC32C` is a pure bit-by-bit, right-shifting Castagnoli reference
implementation: polynomial `0x82F63B78`, initial/final XOR `0xFFFFFFFF`, no extra
augmentation or reflection. The codec extends an unfinalized header register
over payload bytes, excluding both checksum fields. No NIF or native dependency
is used. All six RFC CRC vectors passed before Record was integrated. A separate
test-only normal-polynomial, left-shifting oracle checks generated frames and
the maximum-size boundary independently.

The 18 binary fixtures contain the approved literal bytes, copied into a fixed
manifest and mechanically converted without calling Record or computing CRCs.
The maintenance script refuses to overwrite different existing bytes. Tests
never run that script or regenerate fixtures. Encoder and decoder fixture tests
are separate, and the suite compares the files and manifest against RFC literals.

There are no format or normative behavior deviations and no newly discovered
wire-format compatibility or data-loss concern. Physical success is not semantic
acceptance or applied checkpoint progress; incomplete results never authorize
repair. CRC collisions, undetectable clean suffix loss, and future Event/recovery
integration risks remain the already documented limitations. Those later layers
are not implemented or claimed safe by these tests.

## Commands and results

| Command | Result |
| --- | --- |
| `mix --version` | Elixir/Mix 1.20.2, Erlang/OTP 29 |
| `mix deps.get` | Passed after approved sandbox retry; test-only StreamData 1.4.0 locked, no transitive runtime dependency |
| `mix test test/tay/storage/crc32c_test.exs` | 8 passed before Record integration; an Elixir bitstring pin warning was subsequently corrected |
| `elixir test/fixtures/storage/record/v1/materialize.exs` | Verified/materialized all 18 literal binary fixtures; no codec invoked |
| `mix test test/tay/storage` | First test-helper build failed on an accumulating module attribute; corrected, then 54 passed |
| `mix test test/tay/storage --seed 123456` | Expanded suite: 64 passed, then 66 passed after isolation tests (7 properties, 59 ordinary tests) |
| `mix format` | Passed after edits |
| `mix format --check-formatted` | Final run passed, exit 0 |
| `mix compile --warnings-as-errors` | Final run passed, exit 0 |
| `mix test` | Final run passed, exit 0: **85 total cases, 78 ordinary tests + 7 properties**, seed **502739** |
| `mix test test/tay/storage/record_property_test.exs --seed 654321` | 7 properties passed, exit 0 |

The initial dependency fetch was blocked by Mix's TCP lock in the sandbox and
was retried with approval. An earlier full suite passed 85 cases but warned that
the fixture manifest/maintenance script were not test files. `test_ignore_filters`
now explicitly excludes that fixture directory from discovery; the final run
has no such warning. Existing application stop/restart tests emit expected
application lifecycle notices, not failures.

Properties run inside ordinary `mix test`, inherit its reported seed, and have
explicit generation counts totaling 2,340 cases per complete property run. They
cover round trips, exhaustive small and sampled larger truncations, arbitrary
binary/adversarial input, length mutations, incremental CRC, and resource-limit
retry. Fixed fixtures are not replaced by these properties. Additional tests
cover all 64,770 assignable type/schema pairs, every valid fixture's strict
prefixes and single-bit mutations, the A/B/C length case, all reserved values,
argument/option precedence, sequence independence, opaque ETF-looking bytes,
and the 16 MiB boundary. The prior 19 Phase 0 tests remain passing.

## Complete project-file inventory

Modified (5):

- `README.md`
- `docs/architecture.md`
- `docs/phase-1-storage-format-rfc.md` — approval/status wording only; normative format unchanged
- `lib/tay.ex` — documentation only
- `mix.exs` — test-only dependency, test support compilation, fixture discovery exclusion

Created (33):

```text
docs/phase-1-implementation-report.md
lib/tay/storage/crc32c.ex
lib/tay/storage/record.ex
mix.lock
test/support/storage_helpers.ex
test/tay/storage/crc32c_test.exs
test/tay/storage/record_boundary_test.exs
test/tay/storage/record_decode_test.exs
test/tay/storage/record_encode_test.exs
test/tay/storage/record_fixture_test.exs
test/tay/storage/record_isolation_test.exs
test/tay/storage/record_property_test.exs
test/fixtures/storage/record/v1/README.md
test/fixtures/storage/record/v1/manifest.exs
test/fixtures/storage/record/v1/materialize.exs
test/fixtures/storage/record/v1/f01.bin
test/fixtures/storage/record/v1/f02.bin
test/fixtures/storage/record/v1/f03.bin
test/fixtures/storage/record/v1/f04.bin
test/fixtures/storage/record/v1/f05.bin
test/fixtures/storage/record/v1/f06.bin
test/fixtures/storage/record/v1/f07.bin
test/fixtures/storage/record/v1/f08.bin
test/fixtures/storage/record/v1/f09.bin
test/fixtures/storage/record/v1/f10.bin
test/fixtures/storage/record/v1/f11.bin
test/fixtures/storage/record/v1/f12.bin
test/fixtures/storage/record/v1/f13.bin
test/fixtures/storage/record/v1/f14.bin
test/fixtures/storage/record/v1/f15.bin
test/fixtures/storage/record/v1/f16.bin
test/fixtures/storage/record/v1/f17.bin
test/fixtures/storage/record/v1/f18.bin
```

Dependency downloads in ignored `deps/` and generated build artifacts in ignored
`_build/` are not source changes. Phase 0 configuration, supervision, job/worker
implementation, existing tests, and `TAY_PLAN.md` were not modified.

## Git limitation and phase boundary

`git status --short` returned exit 128: this directory is not a Git repository.
The fixtures were created and verified, but **no Git commit was possible**.
No repository was initialized and no commit was claimed. Version-control setup
or committing these files in the intended repository requires a separate step.

Work stops at Phase 1. No later RFC or implementation has begun.
