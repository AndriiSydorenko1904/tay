# Permanent Tay v1 record fixtures

These 18 binary files contain the literal approved bytes in
[RFC §18.1](../../../../../docs/phase-1-storage-format-rfc.md). Their numeric
types/schemas are conformance identifiers, not production Event allocations.

| File | Contract exercised |
| --- | --- |
| `f01.bin` | Minimal valid frame, empty payload |
| `f02.bin` | Opaque binary payload, embedded magic, invalid UTF-8 |
| `f03.bin` | Maximum type/schema/sequence |
| `f04.bin` | Length mutation with bad header CRC |
| `f05.bin` | Bad record CRC |
| `f06.bin` | Unsupported framing version |
| `f07.bin` | Assignable type independent of semantic support; physical success |
| `f08.bin` | Unsupported nonzero flags |
| `f09.bin` | Nonzero schema independent of semantic support; physical success |
| `f10.bin` | Checksummed maximum-length header, incomplete payload |
| `f11.bin` | Representable uint32 maximum violates v1 hard limit |
| `f12.bin` | One byte above hard limit |
| `f13.bin` | Invalid framing version zero |
| `f14.bin` | Reserved type zero |
| `f15.bin` | Reserved type 255 |
| `f16.bin` | Invalid schema zero |
| `f17.bin` | Invalid sequence zero |
| `f18.bin` | Third contiguous physical record |

`manifest.exs` preserves literal hex and exact expected physical results. No
fixture overrides the default decoder budget. `materialize.exs` mechanically
converts those literals to binary for initial creation; it never loads Tay,
calculates CRCs, or overwrites an existing file. It is not part of any test or
build hook:

```sh
elixir test/fixtures/storage/record/v1/materialize.exs
```

Tests read the binary files as committed compatibility anchors. They never
regenerate them with the encoder. Encoder and decoder fixture tests are separate;
the manifest and RFC literal comparison provides an additional byte-level check.
The 16 MiB payload is constructed deterministically only in boundary tests,
anchored by F10 and an independent checksum oracle, not stored as a large fixture.

Do not repair negative fixtures or change these expected bytes to make tests
pass. A v1 byte incompatibility requires review and an explicit version/migration
boundary. Physical fixture success is not permission to replay unknown events.
