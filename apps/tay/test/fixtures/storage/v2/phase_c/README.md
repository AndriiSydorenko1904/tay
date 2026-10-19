# Phase-C schema-1 retention fixtures

These new literal fixtures do not replace any Phase-B fixture. `manifests.hex`
contains label/hex pairs with STORE_ID=1, epoch ID=2, captured_at=3,600,000,
empty source/base inventory, and tail ID/first sequence=1. `current.hex` binds
the `bounded` (24 hours) manifest by SHA256. Infinite encoding is anchored too.

The inert Value bytes were independently assembled from the documented tags,
big-endian integer/length fields and sorted ASCII keys, not by Authority/Value
encoding. CRC32C was calculated using reflected polynomial 0x82f63b78,
initial/final XOR 0xffffffff. SHA256 uses the standard crypto primitive.
Malformed fixtures have valid framing, lengths and CRC: refusal must come from
the retention schema, not accidental checksum damage. `maximum` is
floor((2^63-1)/3,600,000); `over_maximum` differs by one hour.

Keep these literals stable; never regenerate them to accommodate encoder bugs.
