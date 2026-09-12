# Phase 2 implementation report

Phase 2 only is implemented against the approved
[segment/rotation RFC](phase-2-segment-format-rotation-rfc.md) and the user's
subsequent approval of the native Port, Linux-only strict sync, and explicit
production data-directory gates. No RFC bytes or Phase 1 contracts were changed.
Phase 3 has not been started.

## Implemented scope and boundaries

- Pure 28-byte STORE, 44-byte segment header and 64-byte sealed footer codecs;
  20-digit canonical names; checked IDs, sequences, counts and physical limits.
- Bounded positional parsing with normative validation precedence, incremental
  segment CRC32C, exact EOF, no scan-forward, and distinct incomplete, corrupt,
  unsupported-physical-feature, continuity and resource classifications.
- Full directory discovery and store-wide topology/identity validation. Only
  the highest segment may be active. Recognized staging remains untouched.
- Supervised temporary Writer with a linked native Port. The helper exclusively
  owns flock and every writable FD. No BEAM code opens writable segment FDs.
- Explicit new-store bootstrap and narrowly proved bare-header genesis
  completion; immutable STORE publication without replacement.
- One-record append, selected write/sync receipts, seal, R0–R7 rotation and
  highest-sealed empty successor creation. No records are written to stages.
- Path/inode/extent validation, exact positive write counts, unknown-count
  reporting for failed pwrite, and permanent poisoning on uncertain operations.
- Production startup requires explicit `data_dir`; the root supervisor stays
  empty. The internal Writer must be explicitly supervised by its caller.

Structural file/parent-directory barriers apply in development write mode too;
write-mode record appends omit the per-record file sync. All strict append
receipts require successful file sync after verified bytes, plus previously
completed ancestor, STORE and segment publication barriers. Acquisition syncs
every ancestor entry, including existing entries that could have come from an
interrupted earlier directory-creation attempt.

Physical readiness is not semantic recovery readiness. Assignable unknown
Record types/schemas remain physically valid; neither Reader nor Writer adds
an Event registry. No repair, truncation, stage deletion, segment deletion,
snapshot, manifest, compaction, Event encoding, projection, checkpoint or
application idempotency was implemented.

## Native boundary and platform assumptions

The complete binary protocol is documented in [c_src/README.md](../c_src/README.md).
Its control version and request IDs are independent of the disk format. Requests
are serialized and bounded; timeout, missing/mismatched reply or helper exit
does not establish whether a mutation occurred. There is no mutation retry.
Healthy shutdown acknowledges only after closing all owned descriptors and
releasing the lock. An unresponsive helper may delay a later owner's acquisition;
that is not permission to bypass the lock.

Native filesystem calls used:

- `open("/")`, then `openat` with `O_NOFOLLOW`, `O_DIRECTORY`, `O_CLOEXEC`,
  appropriate `O_RDONLY`/`O_RDWR`, and `O_CREAT|O_EXCL` for new stages/lock;
  inspected regular-file opens also use `O_NONBLOCK`.
- `mkdirat`, `fstat`, `fstatat(AT_SYMLINK_NOFOLLOW)`, `fstatfs`,
  `flock(LOCK_EX|LOCK_NB)`, `pread`, exactly one `pwrite` per write request,
  `fsync` for files/directories, and non-retried `close`.
- Linux: `syscall(SYS_renameat2, ..., RENAME_NOREPLACE)`; no replacing fallback.
- macOS development: `fgetattrlist(ATTR_VOL_CAPABILITIES)` capability check and
  fd-relative `renameatx_np(..., RENAME_EXCL)` publication.
- Directory enumeration uses `fdopendir`/`readdir`/`closedir`. Port transport
  uses stdin/stdout `read`/`write`; only transport interruptions are retried.

There is no native CRC, ETF, shell-command interpreter, truncate or unlink
operation. Fault injection is compiled into a separate test helper only.
Production Elixir builds omit the test-control API and transition-hook branches.

Linux strict sync requires `validated_filesystem: true` and a supported local
ext-family, XFS or Btrfs filesystem, together with working filesystem capabilities.
That flag is an operator assertion about the actual mount/controller/device, not
automatic hardware certification. Unsupported network, temporary and overlay
filesystems fail strict startup, without downgrade. macOS strict sync is rejected
before creating storage; development write mode permits structurally capable
local APFS/HFS. Linux development write also permits tmpfs/overlay.

Actual verification targets were macOS/APFS write mode and a Linux/Btrfs Docker
volume for strict sync, with Elixir 1.20.2 / OTP 29. The image was `elixir:1.20.2`,
digest `sha256:c915d900894e1d664cd8ed72fd2c38fce72b612cc1757d57f86a0cc62e62dd79`.
The host native build used Apple clang 21; the Linux image used its system C
compiler. Both builds use C11, `-Wall -Wextra -Werror -Wformat=2`.

No physical power-cut, device-cache fault, XFS/ext deployment certification,
macOS F_FULLFSYNC protocol, or release-artifact installation was tested. Process
crash and syscall-failure tests validate software ordering and fail-closed
behavior; they cannot prove that hardware honors sync. The RFC's surviving-byte
limits, including undetectable clean suffix loss if the storage contract is
violated, remain unchanged. Relevant syscall contracts are
[Linux fsync](https://man7.org/linux/man-pages/man2/fsync.2.html),
[rename](https://man7.org/linux/man-pages/man2/rename.2.html), and
[flock](https://man7.org/linux/man-pages/man2/flock.2.html).

## Golden provenance and fault coverage

The 22 permanent binary artifacts implement RFC S01–S15, including the five
selected S10 cuts and both S13 successor anchors. S15 composes existing S05 and
the independently pinned ID2/FIRST4 header; it does not need duplicate bytes.
The literal manifest was constructed independently in JavaScript using the
reflected Castagnoli polynomial and RFC vectors, with unchanged Phase 1
F01/F02/F18 literal bytes. Production encoders/checksums did not produce these
expected values. Tests also use a separate normal-polynomial CRC oracle.

Pinned checks include STORE CRC `AE533C93`, header CRC `3D7C68B9`, single-record
segment/footer CRCs `CB674BB0` / `5C6FD9B9`, and three-record segment/footer CRCs
`8E145CFC` / `54DC2AE8`. S09 deliberately changes the segment CRC to `CB674BB1`
while recomputing the footer CRC to `AE045ABA`. The materializer refuses to
overwrite differing existing bytes; tests only read fixtures.

Coverage includes:

- All 63 partial footer lengths; every single-bit mutation of the fixed sealed
  three-record segment; corrupt length before later valid records; unknown
  assignable semantics; payload-embedded magic; hard/resource limit separation.
- Exact 1 GiB valid sealed geometry from a lazy logical stream, using at most
  one cached record rather than a 1 GiB fixture or allocation. The caller's
  chosen reducer accumulator remains the caller's memory responsibility.
- Maximum 16 MiB records, exact rotation threshold, lowered target after reopen,
  names/aliases/links, zero files, identity mismatch, missing IDs, and continuity.
- Eleven helper-crash boundaries spanning R0–R7, including create, sync and close
  substeps; exact visible canonical set, stage count, retained prefix, sequence
  and restart observations. Stages are retained across restart.
- Nine rotation I/O-failure boundaries, including both writable closes, footer
  and header file sync, publication, directory sync and active open.
- Short record/footer/header/STORE writes, disk-full and interrupted/error
  results, unknown pwrite count, full mutation with lost reply, timeout,
  mismatched reply ID, lost lock FD, and poison/no-retry behavior.
- Competing segment and STORE publication; unsupported no-replace and directory
  sync errors; a visible but unacknowledged successor after failed directory
  sync; absent successor before publication. No replacing fallback exists.
- Exclusive ownership against an independent BEAM, stale lock inode reuse,
  irrelevant PID-file contents, lock symlink/hard-link rejection, lock-path
  substitution, helper/writer death, and supervision without automatic retry.
- Independent-VM write and strict-sync acknowledgements followed by abrupt VM
  exit and physical reopen. Strict append/sync failures never return success.
- Malformed/unknown Port packets before mutation, owner-only access, production
  absence of fault commands, and ancestor-chain startup barriers.

## Commands and results

All final commands below exited 0. Properties run in ordinary ExUnit, not in a
separate unexecuted suite.

| Command | Final result |
| --- | --- |
| `mix format --check-formatted` | Passed; no output |
| `mix compile --warnings-as-errors` | Passed; dev and native compilation clean |
| `mix test` | 178 passed: 8 properties + 170 tests; 6 skipped; seed 357492; 8.8 s |
| Linux full command below | 183 passed: 8 properties + 175 tests; 1 skipped; seed 873510; 7.4 s |
| `TAY_LARGE_SEGMENT_TEST=1 mix test test/tay/storage/segment_large_test.exs --warnings-as-errors` | 1 passed; 58.5 s |
| Sanitizer command below | 53 passed; seed 391512; 2.7 s; no ASan/UBSan diagnostics |
| `elixir test/fixtures/storage/segment/v1/materialize.exs` | Verified all 22 pinned artifacts |
| `git diff --check` | Passed; no whitespace errors |
| Phase 1 unchanged check below | Passed; zero diff |
| Production startup command below | Missing path rejected; explicit path accepted; empty supervisor; no storage created; no production fault API |

The six ordinary macOS skips are the five Linux-only strict-sync tests and the
opt-in 1 GiB test. Linux skips only that 1 GiB test, which passed separately.
The unchanged Phase 1 suite was run via `mix test test/tay/storage` after every
one of the ten implementation steps, each successfully; its baseline was 66
passed (7 properties + 59 tests). The final full runs include that same suite.

Linux command:

```sh
docker run --rm \
  --mount type=bind,src=/Users/snake/projects/tay,dst=/workspace \
  --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data \
  --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build \
  -w /workspace -e MIX_BUILD_PATH=/tay-build -e MIX_HOME=/tay-build/mix \
  -e TAY_TEST_DATA_ROOT=/tay-data -e TAY_TEST_SYNC=1 \
  elixir:1.20.2 mix test --warnings-as-errors
```

The test volume was checked with this exact command and reported `btrfs`:

```sh
docker run --rm --mount type=volume,src=tay-phase2-20260912-validation,dst=/tay-data elixir:1.20.2 stat -f -c '%T' /tay-data
```

Hex was installed into the separate Linux build cache with:

```sh
docker run --rm --mount type=volume,src=tay-phase2-20260912-build,dst=/tay-build -e MIX_HOME=/tay-build/mix elixir:1.20.2 mix local.hex --force
```

This installed Hex 2.5.1. The two named Docker volumes remain test/build caches;
they are not Tay production storage defaults. Test cases remove only their own
disposable fixture directories. No user storage or repository file was deleted.

Sanitizers:

```sh
TAY_NATIVE_SANITIZE=1 MIX_BUILD_PATH=_build/sanitized mix test test/tay/storage/native_test.exs test/tay/storage/native_protocol_test.exs test/tay/storage/storage_lifecycle_test.exs test/tay/storage/storage_ownership_test.exs --warnings-as-errors
```

Production startup, including the expected negative case:

```sh
MIX_ENV=prod mix run --no-start -e 'Application.delete_env(:tay, :data_dir); {:error, {:tay, {{:invalid_config, :data_dir, message}, {Tay.Application, :start, _}}}} = Application.ensure_all_started(:tay); IO.puts(message); Application.put_env(:tay, :data_dir, "/operator-configured/tay-startup-check"); {:ok, _} = Application.ensure_all_started(:tay); [] = Supervisor.which_children(Tay.Supervisor); false = File.exists?("/operator-configured/tay-startup-check"); Code.ensure_loaded!(Tay.Storage.Native); false = function_exported?(Tay.Storage.Native, :fault, 6); IO.puts("production startup with explicit path: OK; empty supervisor; no storage I/O; no fault API")'
```

The sandbox initially blocked Mix's local TCP build lock for some environment-
prefixed commands; the approved outside-sandbox reruns succeeded. An intermediate
non-test compilation exposed an unreachable test-hook error branch; production
compilation now omits that branch rather than suppressing warnings. Final runs
above are after the fix.

Phase 1 unchanged check:

```sh
git diff --exit-code -- lib/tay/storage/record.ex lib/tay/storage/crc32c.ex test/fixtures/storage/record test/tay/storage/record_boundary_test.exs test/tay/storage/record_decode_test.exs test/tay/storage/record_encode_test.exs test/tay/storage/record_fixture_test.exs test/tay/storage/record_isolation_test.exs test/tay/storage/record_property_test.exs test/tay/storage/crc32c_test.exs
```

## Complete created/modified file inventory

Modified (6):

```text
README.md
docs/architecture.md
lib/tay.ex
lib/tay/application.ex
lib/tay/config.ex
mix.exs
```

Created implementation/documentation/support files (11):

```text
c_src/README.md
c_src/tay_storage_helper.c
docs/phase-2-implementation-decomposition.md
docs/phase-2-implementation-report.md
lib/tay/storage/native.ex
lib/tay/storage/reader.ex
lib/tay/storage/segment.ex
lib/tay/storage/segment/parser.ex
lib/tay/storage/writer.ex
test/support/native_helpers.ex
test/support/segment_helpers.ex
```

Created tests (14):

```text
test/tay/storage/native_protocol_test.exs
test/tay/storage/native_test.exs
test/tay/storage/segment_codec_test.exs
test/tay/storage/segment_discovery_test.exs
test/tay/storage/segment_large_test.exs
test/tay/storage/segment_parser_test.exs
test/tay/storage/storage_append_test.exs
test/tay/storage/storage_bootstrap_test.exs
test/tay/storage/storage_lifecycle_test.exs
test/tay/storage/storage_linux_sync_test.exs
test/tay/storage/storage_ownership_test.exs
test/tay/storage/storage_rotation_test.exs
test/tay/storage/storage_seal_test.exs
test/tay/storage/storage_supervision_test.exs
```

Created fixture artifacts and documentation (25):

```text
test/fixtures/storage/segment/v1/README.md
test/fixtures/storage/segment/v1/manifest.exs
test/fixtures/storage/segment/v1/materialize.exs
test/fixtures/storage/segment/v1/STORE
test/fixtures/storage/segment/v1/s01.tay
test/fixtures/storage/segment/v1/s02.tay
test/fixtures/storage/segment/v1/s03.tay
test/fixtures/storage/segment/v1/s04.tay
test/fixtures/storage/segment/v1/s05.tay
test/fixtures/storage/segment/v1/s06.tay
test/fixtures/storage/segment/v1/s07.tay
test/fixtures/storage/segment/v1/s08.tay
test/fixtures/storage/segment/v1/s09.tay
test/fixtures/storage/segment/v1/s10_1.tay
test/fixtures/storage/segment/v1/s10_3.tay
test/fixtures/storage/segment/v1/s10_4.tay
test/fixtures/storage/segment/v1/s10_36.tay
test/fixtures/storage/segment/v1/s10_63.tay
test/fixtures/storage/segment/v1/s11.tay
test/fixtures/storage/segment/v1/s12_tail.tay
test/fixtures/storage/segment/v1/s12_duplicate.tay
test/fixtures/storage/segment/v1/s13_next.tay
test/fixtures/storage/segment/v1/s13_correct_next.tay
test/fixtures/storage/segment/v1/s14.tay
test/fixtures/storage/segment/v1/s14_STORE
```

Total: 50 created, 6 modified. The approved
`docs/phase-2-segment-format-rotation-rfc.md` was already untracked before this
implementation and remains unchanged; it is not counted as newly created here.
Concurrent inferred `@spec` additions in `segment.ex` were preserved, with the
unsupported-flags result included to match the implementation. No commits were
made. Ignored build artifacts, disposable test directories and Docker caches are
not source files in this inventory.

## Remaining dependencies — not implemented

Phase 3 must separately approve repair authorization and evidence, treatment of
torn records/footers, acknowledged-versus-complete physical history, and any
applied checkpoint/snapshot anchor. An incomplete classification alone never
permits truncation. No such policy is inferred by this implementation.

Event/insertion integration must define durable encoding and type/schema support,
validate every event before projection or normal-recovery mutation, and define
unknown-commit reconciliation/idempotency. In particular, the Phase 2 internal
Writer must not be wired into automatic semantic recovery before that gate.
Unknown semantics must stop recovery and leave storage unchanged. Physical
cursor/sequence advancement is not an applied replay checkpoint.

Storage startup supervision/readiness wiring belongs to that later integration.
Deletion/retention, compaction, snapshots and manifests require their own approved
protocols. macOS strict power-loss sync remains outside Phase 2. This report does
not start any of those designs or implementations.
