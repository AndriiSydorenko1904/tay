# Persistent benchmark fixtures

- Reuse prepared compaction fixtures across trials and sessions. Before seeding,
  inspect `${XDG_DATA_HOME:-$HOME/.local/share}/tay/bench-fixtures` for a compatible
  fixture and verify its manifest/catalog. Do not silently regenerate missing or
  incompatible fixtures; report the reason before creating a new versioned fixture.
- This directory and any other user-designated fixture store are persistent user
  data. Do not delete, overwrite, move, or include them in cleanup, even after a
  successful benchmark. Deletion requires an explicit user instruction naming the
  fixture. General instructions to run tests or clean temporary files do not count.
- Keep canonical fixtures outside the checkout, temporary directories, container
  writable layers and disposable volumes. Export and verify a completed fixture
  on the persistent host before removing its producer container or filesystem.
- Mount canonical fixtures read-only in benchmark containers. Run Engines and
  compaction only against fresh catalog-verified restored copies. Keep trial
  output separate from canonical fixtures and their backups.
- Preserve a separate backup of each canonical fixture and its manifest/catalog.
  Record the persistent paths, producer revision, durability and hashes in the
  benchmark report. Never claim a fixture is saved when only its metadata exists.

See `bench/README.md` for fixture layout and commands.
