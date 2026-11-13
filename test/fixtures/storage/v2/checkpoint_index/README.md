# Checkpoint index compatibility

`format2.json` freezes the descriptor Value encoding, the 64-byte index header,
an immutable page and its authenticated references to another epoch.
`format3-empty.json` freezes the current seven-root descriptor and header.
Tests read these literal bytes; do not regenerate them when changing the
encoder. New format changes need new fixtures while existing fixtures remain
readable.
