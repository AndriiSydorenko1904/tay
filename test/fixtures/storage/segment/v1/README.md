# Segment v1 compatibility fixtures

The literal manifest is independently constructed with reflected polynomial
0x82F63B78, initial/final XOR 0xFFFFFFFF, using RFC §29 vectors and unchanged
Phase 1 F01/F02/F18 literal record bytes. No production Segment, Record, or CRC
implementation generated these expected bytes. Tests independently cross-check
normal polynomial 0x1EDC6F41 with explicit reflection, then test the production
code against these fixed files. STORE CRC is AE533C93; header ID1/FIRST1 CRC
3D7C68B9; single-record segment/footer CRCs CB674BB0 / 5C6FD9B9;
three-record segment/footer CRCs 8E145CFC / 54DC2AE8.

S01–S14 follow RFC §29. S07 has a byte-valid ID1 header but is checked against
filename ID2. S13 pairs S04 (LAST1) with s13_next (ID2/FIRST4) and must fail;
s13_correct_next is its valid FIRST2 variant. S15 pairs S05 (LAST3) with
s13_next and must pass. s14_STORE independently pins the zero-identity failure.

Run `elixir test/fixtures/storage/segment/v1/materialize.exs` explicitly to
materialize missing files or verify them. It refuses to overwrite different
existing bytes. Tests only read the fixed files and never regenerate them.
