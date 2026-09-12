# Packaging and consuming-release qualification

This is a local qualification procedure, not publication authorization. The Mix
version remains `0.1.0-dev`; phase Git tags do not select a production package
version. No license has been chosen. Hex therefore warns about the empty license
list during a private build. Choosing a license, selecting a release version and
the R5 measured production-envelope approval remain explicit release decisions.
No package was published and no commit, tag or release was created by this work.

## Build and runtime boundary

The source package has an explicit allowlist: `lib/`, the unchanged
`c_src/tay_storage_helper.c`, its platform README, the external offline
`scripts/tay_cold_copy.py` tool, `mix.exs`, `.formatter.exs`, README and Markdown
documentation. The restore script is shipped as a source-package operational
tool, not a dependency of the running release; use it from a separately prepared
offline operations environment. It excludes checkout-local `priv/` executables, tests/test providers,
fixtures, configuration, dependencies, build output, Git metadata and storage.
The native executable is compiled for the consuming build environment, not copied
from a developer's machine. It is a regular executable file in the application's
release `priv/` directory. Non-test compilation removes only the exact generated
fault-enabled helper if a prior test build left one in that output directory.

Building requires Elixir 1.20, Erlang/OTP, Mix and a C11 compiler available as `cc`.
The qualification environment uses Elixir 1.20.2 and OTP 29.0.2. There are no
production Hex dependencies; `stream_data` is test-only. Existing Hex is needed
to exercise the source-package builder. The local harness uses `HEX_OFFLINE=1`
and an isolated writable Hex cache: it does not install or fetch dependencies.

Deploy a release built on the same OS, CPU architecture and compatible ABI/system
libraries as its destination. Included ERTS and the native helper do not make
releases cross-platform or statically linked. A deployed release requires its
OS runtime libraries and normal Unix shell utilities, but neither a C compiler,
Mix, system Elixir nor a source checkout. Startup opens the built helper; it does
not compile one. Linux strict-sync storage additionally requires the documented
validated local-filesystem/deployment assumptions. macOS is a development platform,
not a production `:write` override. See [operations](operations.md) and
[production limits](production-limits.md).

Production configuration supplies an explicit `:tay, :data_dir`. Starting the
Tay application alone starts no writable Engine or store. Initialize a genuinely
new store explicitly, then supervise an Engine with trusted static worker/queue
configuration. Never use the package build or release boot as storage bootstrap.

## Reproducible local qualification

Run the focused opt-in package test with already-installed Hex:

```sh
TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors
```

On Linux, first independently validate the local filesystem and deployment. Only
then use an existing writable directory on that filesystem for test artifacts:

```sh
stat -f -c %T /validated/local/test-root
TAY_TEST_DATA_ROOT=/validated/local/test-root TAY_TEST_SYNC=1 TAY_PACKAGE_TEST=1 \
  mix test test/tay/system/package_test.exs --warnings-as-errors
```

An observed filesystem type is necessary evidence, not proof of truthful device
barriers or power-loss behavior. Do not set `TAY_TEST_SYNC=1` to bypass unsupported
filesystem qualification. These paths contain only newly generated synthetic
data, never production storage.

The test performs the following assertions:

1. `mix hex.build --unpack --output <temporary-consumer>/vendor/tay` creates a
   private source package using its actual metadata/allowlist; frozen native source
   equals the checkout's bytes and prohibited directories are absent.
2. A distinct Mix application consumes that unpacked package as a production path
   dependency. Its own worker is ordinary consumer code, not Tay test support.
   It compiles with warnings as errors and builds a production release with ERTS.
3. The release is relocated. Original consumer, dependency, build and assembled
   release paths become unavailable before the relocated release is invoked.
4. The helper has executable permissions, its platform architecture is reported
   by `file`, and actually executing it proves host compatibility. Its test-only
   native opcode returns `invalid_protocol`; no fault-enabled executable or
   exported fault API/test provider/StreamData/Mix is present at runtime.
5. The runtime PATH includes only required Unix utilities, not `cc`, `mix`, `erl`
   or `elixir`. The release boots and checks Record v1 round-trip compatibility.
   Production development/test switches are rejected, and application-only
   startup remains non-mutating.
6. On validated Linux sync mode the deployed release explicitly initializes a
   new store, inserts a job, executes its consumer worker, stops and recovers the
   completed job in a fresh Engine generation. The recorded external effect is
   unchanged on restart. This is a no-crash completion test, not an exactly-once
   external-effects claim. On macOS it deliberately does not activate a writable
   production Engine and proves no store was created.

Set `TAY_PACKAGE_KEEP=1` to retain successful local artifacts. Every failed run
automatically preserves its printed fresh `tay-package.*` directory for diagnosis;
only that exact freshly-created directory is removed after a complete successful
run. The test is skipped in ordinary suites unless explicitly enabled.

## Automated qualification

`.github/workflows/qualification.yml` provides an explicit manual-dispatch matrix
for macOS development and Linux strict sync. It runs ordinary/frozen/race tests,
sanitizers, 10,000-job and 1 GiB/many-segment suites, and the consuming-release test.
Linux creates a new disposable loopback Btrfs filesystem, verifies the mounted
type before enabling strict-sync tests and never formats a pre-existing device.
This virtual filesystem does not certify production hardware or prove power cuts.
Restore/capacity evidence and final R5 sign-off still belong to the complete
Phase 6 implementation report; a green workflow is not publication approval.

The workflow has read-only repository permissions, no persisted checkout
credentials, immutable action revisions and no publishing step. Its BEAM setup
uses a pinned Node24 action revision supporting strict tool versions; see the
[setup action definition](https://github.com/erlef/setup-beam/blob/54075bcc5e249e4758d363f27d099f55d843f124/action.yml).
The checkout security-backport revision is also
[pinned](https://github.com/actions/checkout/commit/11d5960a326750d5838078e36cf38b85af677262).
The workflow has not been dispatched as part of the local implementation. Exact
local platform results and any hosted-runner skips must be reported separately.

## Release checklist and remaining decisions

- Review the complete Phase 6 report, measured production profile, fail-closed
  cases, restore procedure and unsupported platforms. Resolve R5 explicitly.
- Select an actual release version and license; include the approved license file
  in the package allowlist before any publication. Do not infer either from tags.
- Qualify the actual target-specific consumer release and its native permissions,
  architecture/runtime libraries, filesystem barriers and deployment configuration.
- Retain the frozen fixture manifests and compatibility matrix. Packaging may not
  alter formats, semantic capability checks, test-only API exclusion or durability.
- Publication, signatures, commits and tags require separate authorization.
