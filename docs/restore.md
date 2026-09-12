# Cold backup, offline inspection and restore

This procedure is an **offline whole-store byte copy**, not a snapshot, repair,
retention mechanism or an activation ticket. Stop all Engines using the source
store first. Never run source and restored copies concurrently: they retain the
same STORE_ID, which is not distributed fencing. A VM-local fence cannot prevent
independent hosts from running cloned stores.

An acceptable backup may be older than the latest acknowledged job history.
Restoring it explicitly accepts that RPO: later acknowledged jobs may be absent,
and external effects from previously completed jobs may execute again. Record
the backup's acquisition time, operational cutover and accepted RPO separately.
The external checksum catalog identifies bytes, not the latest authoritative
history, external effects, or caller acknowledgements.

## Preconditions and dependencies

- A complete, stopped source store and its **existing** `.tay-owner.lock`.
  Do not create a replacement lock to defeat ownership contention.
- Python 3.8 or newer, its standard library, and a local POSIX filesystem.
  The script uses `fcntl.flock`, descriptor-relative no-follow access, SHA-256,
  and OS exclusive-rename publication. No Python packages are required.
- Strict durable copying requires Linux, successful directory/file syncs, and
  explicit prior validation of the selected local ext4/XFS/Btrfs volume. The
  script checks filesystem types as well as requiring the operator declaration;
  a filesystem-type check is not power-loss/device certification.
- macOS is an explicitly non-durable **development copy** path using exclusive
  Darwin rename. It does not supply Tay's production `:sync` guarantee.
- Existing destination parents; the destination store and output catalog must
  not exist. Keep catalogs and failed-copy staging directories outside every
  STORE namespace. Reject symlinks in any traversed component and hard-linked
  store files; do not follow links to work around a refusal. Pinned ancestor
  inode checks also reject destination/catalog paths that alias the source
  root or segments directory through a bind mount.
- Adequate disk/RAM and the qualified history envelope from
  [production limits](production-limits.md). Copy defaults are operational:
  100,000 directory entries (including the `segments` directory itself) and
  10 GiB of file bytes; inventory stops incrementally at either budget. Override explicitly if a separately
  qualified workload needs more. Replay has its own independent budgets.

The checked-in script is `scripts/tay_cold_copy.py`. Installed package/release
deployment must also carry this external operator tool, or obtain the matching
version from the release artifact. Running Tay itself never invokes Python.

## Inspect before backup

After stopping the source Engine, run a complete locked physical **and Event v1
semantic** inspection. A busy owner, unknown schema, corruption, incomplete tail,
or insufficient replay budget refuses inspection and returns no partial jobs.

```sh
MIX_ENV=prod mix tay.storage.inspect --data-dir /srv/tay/source --durability sync --validated-filesystem
```

This operation uses existing-only inspection acquisition and full pure candidate
reconstruction. It never activates mutations, creates a successor, initializes
storage, publishes ETS, executes workers or returns job payloads. Its successful
summary is aggregate-only and must not be reused as later activation authority.
The next owner must acquire and revalidate the complete store independently.

For development only:

```sh
mix tay.storage.inspect --data-dir /absolute/dev/store --durability write
```

Available inspection budgets are `--max-jobs`, `--max-state-bytes`,
`--max-state-nodes`, `--max-records`, `--max-bytes` and `--deadline-ms`. Increasing
a budget cannot make an unsupported or corrupt physical record valid. There is
no `--force`, offset-mutation, padding, truncation, salvage, or repair option.

## Create a cold backup

Use a new directory and a separate new catalog file:

```sh
python3 scripts/tay_cold_copy.py backup /srv/tay/source /srv/backups/tay-2026-09-13 --catalog /srv/backups/tay-2026-09-13.json --durability sync --validated-filesystem
```

The script acquires the source's existing exclusive lock non-blockingly. Busy
ownership is a refusal, not a signal to retry a mutation or remove a lock. It
copies the entire safe inventory: STORE, lock, every canonical segment including
the active file, recognized retained stages, and any regular unrelated files.
Directories other than `segments`, symlinks and hard-linked files are refused.
Source descriptor identities, directory membership and file hashes are checked
before and after copying. No source file is changed.

A source may contain corrupt bytes; the copy tool is not a second physical/Event
decoder. Its `synced_copy` result describes copied byte durability only and
always says `semantic_validation: required`. It is never sufficient by itself
to call a backup or restored store operationally usable.

## Restore to a new location

Restoring requires the external catalog captured with the selected backup:

```sh
python3 scripts/tay_cold_copy.py restore /srv/backups/tay-2026-09-13 /srv/tay/restored --verify-catalog /srv/backups/tay-2026-09-13.json --catalog /srv/backups/tay-restored-verification.json --durability sync --validated-filesystem
MIX_ENV=prod mix tay.storage.inspect --data-dir /srv/tay/restored --durability sync --validated-filesystem
```

Then configure the Engine's `data_dir` to the restored location and perform a
fresh complete startup/activation. Check the resulting generation and expected
job counts before admitting new work. Keep the source disabled. Do not attach a
previous Writer, ETS projection or operation reply to the new generation.

Checksums cover the exact complete inventory and file bytes, including lock,
STORE, active and older sealed segments and retained stages. A missing highest
active file can otherwise leave a structurally plausible older prefix; this is
why restoring without the selected backup's full external catalog is refused.
The catalog is not a Tay recovery anchor: neither it nor any mismatch permits
reconstructing, omitting, truncating or deleting history. An unsigned catalog is
not tamper authentication; protect it with the backup's access controls.

For development-only copy/restore, replace `--durability sync
--validated-filesystem` with `--durability development`; use `--durability write`
for the separate Mix inspection. Development output never claims synced-copy
durability.

## Publication and failure rules

The copy protocol holds both source ownership and the copied destination lock:

1. Under the existing source flock, inventory and hash all source files. For a
   restore, verify the supplied external catalog before creating destination data.
2. Create a private `.<destination>.tay-copy-<random>` sibling with mode 0700.
   Create copied files with mode 0600; preserve bytes, not source inode identities
   or permissive ownership/modes. Copy STORE last; never synthesize any bytes.
3. In strict mode, fsync **every copied file**, including older sealed files,
   active segment, STORE, lock and retained stages. Short external copy writes
   are completed within this newly created destination file, never on Tay history.
4. Fsync the copied `segments` directory, then the staged store directory.
5. Revalidate pinned source/ancestor identities; exclusively rename the staged
   store to the requested **new-only** destination. The OS no-replace operation
   refuses a destination created concurrently.
6. Fsync the destination parent and every required ancestor up through `/`.
7. Exclusively create the external catalog, fsync it and its ancestor directories.
   Only after every required operation succeeds may the script print success.
8. Release ownership. Full semantic inspection and fresh activation remain
   separate mandatory operations; no lock handoff ticket is produced.

Any error prints a bounded refusal and exits nonzero. It never overwrites or
deletes a failed store, backup, catalog or partial staging copy. A failure after
publication can leave a complete-looking destination but no successful catalog
publication; this is **not acknowledged copy success**. Preserve both the source
and all destination/staging evidence. Diagnose the failure and, if appropriate,
run a separate explicit copy to a different new destination. Never reuse failed
staging bytes to infer an authorized prefix or silently clean them up.

The protocol assumes cooperative exclusion and trusted administrative ownership
of the parent directories. It rejects path/link changes it observes; it is not a
sandbox against a privileged process deliberately bypassing flock or modifying
the store concurrently. Unlinked worker subprocesses/external services must be
stopped/fenced by the application operator as part of the cold-store procedure.

## Verification evidence

`test/tay/system/restore_test.exs` covers whole-history copying and activation,
retained stages, source ownership, no-overwrite publication including a racing
destination, missing lock/STORE/active history, corrupt catalogs/archives,
unsafe links, older-backup RPO and unsupported Event type/schema refusal.
Linux-only cases trace the real file/directory sync order and inject a restored
file-sync error to prove that failed staging is preserved and not published.
These are process/syscall qualification tests, not power-cut certification.
Exact host/platform commands and results belong in the Phase 6 implementation
report; unsupported platforms and storage modes are not implicit passes.
