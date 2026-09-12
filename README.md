# Tay

Tay is an Elixir library under development for embedded durable background jobs,
using a segmented append-only log and reconstructable ETS indexes. The planned
engine has at-least-once execution semantics and no external database or broker.

**Phases 0–2** are implemented: the project foundation, physical record codec,
and segmented filesystem storage. There is no semantic recovery, insertion API,
scheduler, or queue execution yet. Tay is not ready
to process production jobs. Starting the application starts an empty supervisor;
it does not establish storage readiness or a durability guarantee.

## Development

The initial baseline is Elixir 1.20 and Erlang/OTP 29. Verification uses Elixir
1.20.2 and OTP 29; compatibility with other versions has not been established.
There are no third-party runtime dependencies. OTP `:crypto` supplies store IDs
and temporary-name randomness. A C11 compiler is required at build time for the
native filesystem Port; releases must include the built helper in `priv/`.
StreamData is a test-only dependency, locked in `mix.lock`, for codec properties.
ExUnit and the built-in formatter are the
other tooling; Credo and Dialyzer remain deferred.

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Properties run as part of `mix test`, using its reported ExUnit seed. Reproduce
a targeted run with `mix test test/tay/storage --seed 123456`, or run just the
properties with `mix test test/tay/storage/record_property_test.exs --seed 123456`.

`mix run -e 'IO.inspect(Supervisor.which_children(Tay.Supervisor))'` prints `[]`,
reflecting the unchanged empty supervisor.
`Tay.Application` validates configuration and then starts the dedicated
`Tay.Supervisor` module, which provides the standard OTP child specification.

## Configuration

`Tay.Config.new/1` validates options. `Tay.Config.load/0` reads the current `:tay`
application environment. The application validates configuration before startup.
Errors have the shape `{:error, {:invalid_config, key, message}}`.

```elixir
Tay.Config.new(data_dir: "local-development/tay", queues: [default: 10, mailers: 2])
```

Queue names must be unique atoms; limits must be positive integers. An empty
queue list is allowed. The default queues are `[default: 10]`. Unknown and
duplicate options are rejected.

An unset `data_dir` is `nil`. A supplied path must be a nonblank UTF-8 string
without NUL bytes. It is expanded against the working directory when loaded,
without creating files, resolving symlinks, or checking storage permissions.

This repository's `config/config.exs` supplies **provisional development/test
defaults**: `var/tay/dev` and `var/tay/test`. Library consumers do not inherit a
dependency's Mix configuration. There is no production path default in the
configuration module. Production builds fail application startup when `data_dir`
is unset; the embedding application/operator must configure it explicitly.
Development/test application startup may remain storage-free with an unset path.
Every explicit storage session requires a configured path. None of the repository
development/test paths is a production storage contract.

## Worker boundary

```elixir
defmodule ExampleWorker do
  @behaviour Tay.Worker

  @impl true
  def perform(%Tay.Job{args: %{"message" => message}}) do
    IO.puts(message)
    :ok
  end
end
```

`perform/1` can return `:ok`, `{:ok, result}`, or `{:error, reason}`. These are
callback return values; no executor or result persistence exists yet.

`%Tay.Job{}` is an in-memory description with no generated ID, lifecycle state,
or timestamps. Its layout does not define a persisted schema. The example above
defines a callback only; Tay does not dispatch it. `use Tay.Worker`, worker
`new/1` helpers, and `Tay.insert/1` are future API work.

## Physical record codec

`Tay.Storage.Record.encode/1`, `decode/1`, and `decode/2` implement the approved
24-byte Tay v1 header with 28-byte fixed overhead, big-endian integers, header
and record CRC32C, and a 16 MiB hard payload maximum. Payloads are opaque binary
bytes. All types `1..254` and schemas `1..255` are structurally valid, including
pairs the future Event layer will not understand. No event registry is consulted.

`decode/2` accepts only `max_decode_payload_bytes`, an independent resource
budget defaulting to the hard maximum. Success returns exactly one record plus
the untouched remainder. Errors and incomplete results consume no bytes, skip
nothing, and never authorize truncation. A physical cursor is not an applied
replay checkpoint: future continuity, Event validation, and projection layers
must still validate every event; unknown semantics must stop recovery without
changing storage.

The CRC32C implementation is a pure, bit-by-bit reference implementation with no
native dependency. [Fixed binary fixtures](test/fixtures/storage/record/v1/README.md)
anchor compatibility independently of encoder/decoder round trips. No payload
serialization or recovery policy is implemented or approved by the Record codec.

## Physical segment storage

`Tay.Storage.Segment` and its bounded parser implement the approved 28-byte STORE,
44-byte header, 64-byte footer, canonical filenames, and segment integrity rules.
`Tay.Storage.Reader` validates all canonical history and cross-segment continuity.
`Tay.Storage.Writer` is an **internal**, explicitly supervised temporary child for
bootstrap, one-record append, sealing, and R0–R7 rotation. The root application
does not start it automatically. It accepts opaque bytes from a future semantic
validator; physical readiness is not permission to replay jobs.

Only the native Port holds the OS lock and writable file descriptors. An uncertain
operation poisons the session without retry. Incomplete/corrupt canonical bytes
stop startup without repair; recognized header-only staging files are retained.
There is no truncation, stage deletion, segment deletion, or scan-forward recovery.

Strict `:sync` is Linux-only on an operator-validated supported local filesystem;
the default is fail-closed, with no downgrade. macOS provides development `:write`
only when locking and publication capabilities pass, without a power-loss promise.
See the [native protocol and platform assumptions](c_src/README.md),
[permanent segment fixtures](test/fixtures/storage/segment/v1/README.md), and
[Phase 2 implementation/verification report](docs/phase-2-implementation-report.md).
The explicit, slower 1 GiB bounded-parser test is opt-in:

```sh
TAY_LARGE_SEGMENT_TEST=1 mix test test/tay/storage/segment_large_test.exs --warnings-as-errors
```

## Architecture and review input

- [Authoritative development plan](TAY_PLAN.md)
- [Implemented Phase 0–2 architecture and scope](docs/architecture.md)
- [Accepted adversarial review input for the future Phase 1 RFC](docs/phase-1-review-input.md)
- [User-supplied record and segment candidates for future RFC review](docs/storage-rfc-input.md)
- [Approved Phase 1 storage format RFC](docs/phase-1-storage-format-rfc.md)
- [Approved Phase 2 segment/rotation RFC](docs/phase-2-segment-format-rotation-rfc.md)

The accepted review input supplements the plan, including the requirement to
start fixed compatibility fixtures in Phase 1. The supplied record/segment
candidates are preserved as historical design input. The approved Phase 1 RFC
supersedes their record proposal and establishes the v1 physical compatibility
contract. The Phase 2 RFC and its approved implementation gates supersede the
segment candidate. Phase 3 recovery design and implementation remain deferred.
