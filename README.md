# Tay

Tay is an Elixir library under development for embedded durable background jobs,
using a segmented append-only log and reconstructable ETS indexes. The planned
engine has at-least-once execution semantics and no external database or broker.

**Phase 0: project foundation** and **Phase 1: pure binary record codec** are
implemented. There is no persistence I/O, insertion API, scheduler, queue
execution, or crash recovery yet. Tay is not ready
to process production jobs. Starting the application starts an empty supervisor;
it does not establish storage readiness or a durability guarantee.

## Development

The initial baseline is Elixir 1.20 and Erlang/OTP 29. Verification uses Elixir
1.20.2 and OTP 29; compatibility with other versions has not been established.
There are no runtime dependencies. StreamData is a test-only dependency, locked
in `mix.lock`, for codec properties. ExUnit and the built-in formatter are the
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
configuration module. The storage-free Phase 0 application can start with an
unset path; production storage-location semantics will be finalized before
Phase 2. None of these paths is a long-term storage contract.

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
serialization, sequence allocator, segment format, filesystem protocol, or
recovery policy is implemented or approved by the codec.

## Architecture and review input

- [Authoritative development plan](TAY_PLAN.md)
- [Implemented Phase 0/1 architecture and scope](docs/architecture.md)
- [Accepted adversarial review input for the future Phase 1 RFC](docs/phase-1-review-input.md)
- [User-supplied record and segment candidates for future RFC review](docs/storage-rfc-input.md)
- [Approved Phase 1 storage format RFC](docs/phase-1-storage-format-rfc.md)

The accepted review input supplements the plan, including the requirement to
start fixed compatibility fixtures in Phase 1. The supplied record/segment
candidates are preserved as historical design input. The approved Phase 1 RFC
supersedes their record proposal and establishes the v1 physical compatibility
contract. Segment and recovery candidates remain unapproved; Phase 2 has not begun.
