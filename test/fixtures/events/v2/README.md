# rc3 semantic event fixtures

`rc3.json` freezes schema-2 types 11 (schedule delivery/skip) and 12 (schedule
state/checkpoint). Payloads were encoded independently with the canonical Value tags,
UTF-8 strings, big-endian uint64 integers, and lexically sorted map keys. Type 12
preserves the original logical schedule revision and active-job link across
compaction rather than deriving it from a new physical record coordinate.

Type 13 adds the sorted occurrence membership list and completeness flag without
changing either earlier fixture. Its literal payload was independently encoded
in Python using the Value tag table and big-endian lengths/integers.
