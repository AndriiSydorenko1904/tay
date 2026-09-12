# Phase 2 implementation decomposition

The operator's implementation authorization resolves RFC §31: the native Port
boundary is approved; strict `:sync` is Linux-only on an explicitly validated
local filesystem; production requires an explicitly configured `data_dir`.
The RFC's original proposed/status text is historical. Its bytes and ordering
remain normative. This document records implementation choices explicitly.

## Modules and ownership

* `Tay.Storage.Segment`: pure STORE, header, and footer codecs, canonical names,
  limits, and a bounded parser driven by a positional read function. Results
  retain segment/offset/classification; no repair or semantic event registry.
* `Tay.Storage.Reader`: read-only native-file adapter, complete discovery, safe
  staging/name classification, multi-file identity/sequence/topology checks,
  and sequential record reduction. No filesystem mutation or projection.
* `Tay.Storage.Native`: packet encoding/decoding and bounded synchronous Port
  requests from its owning process. Versioned request IDs and explicit errors;
  any uncertain response closes the connection and cannot be retried.
* `Tay.Storage.Writer`: supervised GenServer owning and supervising the linked
  native Port. It allocates sequences, bootstraps, appends, seals, and rotates.
  Helper death or uncertain I/O permanently poisons that writer instance. Its
  child specification is temporary, so supervision cannot silently retry a
  mutation. Explicit reopening requires complete physical reinspection.
* `Tay.Config` / `Tay.Application`: retain lexical configuration normalization;
  enforce missing production `data_dir` as a startup error. Storage sessions
  are explicitly supervised by their caller in Phase 2; application startup
  does not publish recovery readiness before the Phase 3/Event layers exist.

## Native source and wire protocol

`c_src/tay_storage_helper.c` builds into `priv/tay_storage_helper` through a
Mix compiler task. A separate test build enables fault injection; production
has no fault-control commands. No native CRC or payload decoder is introduced.

Port packets have a 4-byte big-endian length, bounded to one maximum Record
plus protocol overhead. Each request carries protocol version 1, an opcode,
and a uint64 request ID. Replies echo all three and contain a status byte,
native errno, an exact known written-byte count, and opcode-specific bytes.
Strings have explicit lengths; integers are big-endian; no ETF or atom
creation is used. Only one request is outstanding for a Port.

Commands cover acquire/lock, scoped directory listing/creation, read-only
open/pread/close, exclusive staging creation, validated active open, one
offset-explicit write, file sync, writable close, no-replace publication,
directory sync, and descriptor/path validation. The helper pins directory
inodes, rejects links/aliases, owns at most one writable canonical FD, and
caps staging files at exactly their header/marker purpose. Linux uses
`renameat2(RENAME_NOREPLACE)`; macOS development uses the fd-relative
`renameatx_np(RENAME_EXCL)` counterpart, subject to capability checks.

Strict mode additionally requires an explicit operator validation assertion
and a supported local Linux filesystem; syscall availability alone does not
establish a hardware power-loss guarantee. Temporary/network storage is never
silently selected for production or accepted for strict durability.

## Fixtures and verification

New permanent files live under `test/fixtures/storage/segment/v1/`, with a
literal hex manifest, provenance/readme, and explicit materializer. They use
the RFC vectors and the unchanged Phase 1 F01/F02/F18 bytes. An independent
normal-polynomial CRC oracle cross-checks each positive and negative vector.

New tests cover codecs, validation precedence, parser properties and bounds,
discovery/topology, native protocol/capabilities, ownership across independent
BEAM instances, bootstrap, append, sealing, rotation, and lifecycle faults.
Support modules hold independent constructors and test-only fault controls.
Linux integration runs on a Docker volume backed by a local filesystem;
macOS tests exercise only `:write` structural behavior. The existing Phase 1
suite runs after each of the ten requested implementation steps.

## RFC reconciliation

No blocking on-disk contradiction was found. Three boundaries are explicit:

* The approval supersedes the RFC's historical implementation-gate prose.
* Pure physical reads cannot establish Event support. Phase 2 exposes internal
  physical storage operations and never advertises semantic recovery readiness.
* A highest sealed file observed after a lost sync response is revalidated and
  synced again through a read-only FD before a successor is created. No sealed
  inode is reopened writable. This satisfies the required old-file barrier.

All incomplete or corrupt canonical history remains untouched. Genesis and
highest-sealed successor creation are the RFC's narrowly authorized operations.
