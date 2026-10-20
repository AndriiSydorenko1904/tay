# Store-v2 literal Record fixtures

`records.hex` contains independently committed lowercase hexadecimal Record-v1
frames. The line label identifies a Store-v2 semantic payload: one
`JOB_SNAPSHOT_V2` and one of each six `JOB_MUTATION_V2` kinds. The sample job
ID is `<<1::128>>`; physical sequence is 1 in each standalone fixture. Tests
read these bytes and refuse changes to their encoding.
