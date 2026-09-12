# Tay filesystem Port v1

`mix compile` builds `tay_storage_helper.c` with the system C compiler into the
application's build `priv/` directory. Releases must include that executable.
No compiler is needed on the release host. CRC32C stays in Elixir. A test build
also produces `tay_storage_helper_test`; only that binary accepts opcode 240.
`TAY_NATIVE_SANITIZE=1` enables AddressSanitizer and UndefinedBehaviorSanitizer.

The supervised `Tay.Storage.Writer` GenServer owns the linked Port. The helper
owns the OS lock, pinned directory descriptors, one optional read descriptor,
and at most one write descriptor. Write kind 1 is canonical, 2 is segment
staging, 3 is STORE staging. A stage accepts only one header/marker-sized write
at offset zero; it cannot receive Record appends. The Writer child is temporary:
supervision cannot automatically restart an uncertain append or rotation.

## Encoding

The transport is Erlang Port `{packet, 4}`: a uint32 big-endian length excluding
those four bytes. Maximum packet length is 16,785,436 bytes. All integers below
are unsigned big-endian. No ETF, text command parser, shell, or dynamic atoms.

Request: `version:u8=1 | opcode:u8 | request_id:u64 | body`.
Reply: `version:u8=1 | opcode:u8 | request_id:u64 | status:u8 | errno:u32 |
written:u64 | body`. Status 0 is success, status 1 a reported error. Replies
must match the outstanding request exactly. An error body is a bounded ASCII
reason identifier; `errno` retains the OS-specific numeric code. `written`
is the known pwrite result, or `UINT64_MAX` when a failed syscall cannot prove
how many bytes changed (decoded as `:unknown`). Zero before an injected syscall
means the call was never issued; it does not authorize retry or sequence reuse.
Loss/timeout/bad response is `:uncertain`, with no inferred mutation outcome.

`str` means `length:u16 | bytes`, with no embedded NUL. Paths are bounded by
PATH_MAX; basenames by 255 bytes and cannot contain `/`, `.` or `..` entries.
`scope:u8` is 0 for data_dir and 1 for segments/. An identity is
`size:u64 | device:u64 | inode:u64 | links:u64 | type:u8 | mode:u32` (37 bytes).
Type is regular=1, directory=2, symlink=3, other=4.

| Opcode | Request body | Success body |
| --- | --- | --- |
| 1 acquire | strict:u8, operator_validated:u8, absolute_path:str | root_created:u8, filesystem_type:u64, helper_pid:u64 |
| 2 list | scope | count:u32, repeated(name:str, identity) |
| 3 mkdir segments | empty | empty |
| 4 open read | scope, name:str | identity |
| 5 positional read | offset:u64, length:u32 | up to length raw bytes |
| 6 close read | empty | empty |
| 7 create stage | scope, name:str | identity |
| 8 open active | name:str, expected_size:u64, device:u64, inode:u64 | identity |
| 9 positional write | offset:u64, all remaining bytes | identity; written count in reply header |
| 10 file sync | empty | empty |
| 11 close writable | empty | empty |
| 12 publish | scope, source:str, target:str, device:u64, inode:u64 | empty |
| 13 directory sync | scope | empty |
| 14 validate paths/FDs | empty | empty |
| 15 diagnostics | empty | helper_pid:u64, write_kind:u8, read_open:u8, filesystem_type:u64, ancestor_syncs:u32 |
| 16 sync read-only file | empty | empty |
| 17 shutdown | empty | empty, after all FDs close and lock releases; then exit |
| 18 acquire existing | strict:u8, operator_validated:u8, max_directory_entries:u32, absolute_path:str | root_created:u8=0, filesystem_type:u64, helper_pid:u64; inspection-only session |
| 19 enable mutations | empty | empty, after deferred barriers; same helper and lock |
| 240 test fault | opcode:u8, occurrence:u32, action:u8, errno:u32, short_count:u64 | empty |

Fault actions are before-call error=1, short pwrite/pread=2, crash after=3, drop reply=4,
crash before=5, lose lock FD=6, mismatched reply ID=7, pwrite returning error=8.
They are compiled out of the production executable and Elixir API. Malformed
control packets are rejected before filesystem operations. Poisoned helpers
permit only cleanup shutdown; a transport failure closes the connection.

Test-only fault targets 241–244 select promotion's ancestor, lock, root and
segments-directory fsync sites respectively. They are not request opcodes or
persisted fields; the occurrence counter can select a particular ancestor.
The test-only Elixir `test_before_acquire` hook installs acquisition faults
before any filesystem operation. Neither hook nor fault API is enabled in a
production build.

## Phase 3 inspection and promotion

Opcode 18 opens only existing, no-follow directories and the existing lock;
it never bootstraps, creates or syncs anything. A missing existing lock is an
operational ownership failure. Enumeration has the caller's nonzero uint32
entry budget as well as the unchanged packet cap; overflow returns no partial
inventory. Inspection permits list/read-only open/pread/close/check/info/shutdown
only. Mutating opcodes and reacquisition are refused, not routed through opcode 1.

The same Writer owns the same Port and lock through physical preflight,
semantic replay, private reduction and revalidation. Only then does it send
opcode 19. Promotion requires no open read/write FD, rechecks capabilities and
identities, resyncs existing ancestor entries without mkdir permission, then
syncs the lock/root/segments directory. It neither bootstraps nor creates a
successor; approved Phase 2 publication remains an explicit subsequent Writer
operation. Failure/uncertainty poisons the owner; no promotion retry is legal.

The native helper enforces capabilities, not Event semantics. The trusted Writer
must establish semantic authorization before promotion. There is no Port transfer,
lock release/reacquire handoff or durable recovery ticket. All Record, STORE and
segment bytes, existing opcode encodings and physical CRC ownership are unchanged.

## Filesystem assumptions and exact syscall boundary

Production operations use `open` for `/`, then `openat` with `O_NOFOLLOW`,
`O_DIRECTORY`, `O_CLOEXEC` and appropriate `O_RDONLY`/`O_RDWR`; file opens also
use `O_EXCL|O_CREAT` for new stages/lock and `O_NONBLOCK` for inspected files.
The helper uses `mkdirat`, `fstat`, `fstatat(AT_SYMLINK_NOFOLLOW)`, `fstatfs`,
`flock(LOCK_EX|LOCK_NB)`, `pread`, one `pwrite` per write request, `fsync` on
files/directories, and `close`. Directory enumeration uses
`fdopendir`/`readdir`/`closedir`. Transport uses `read`/`write` on stdin/stdout.

Linux publication is `syscall(SYS_renameat2, ..., RENAME_NOREPLACE)`. There is
no replacing-rename fallback, ftruncate, unlink, or segment deletion operation.
The Linux adapter allows persistent ext-family, XFS, or Btrfs filesystem types
for `:sync` only with explicit `validated_filesystem: true`; it also executes
lock, file/directory sync, and no-replace capability checks. The assertion must
reflect operator validation of the actual filesystem, mount, controller and
device. It is not evidence that a syscall test proves hardware power-loss
behavior. This implementation run verifies the Linux paths on a Btrfs Docker
volume, not on the container's overlay root. Temporary and network filesystem
types are refused in strict mode. Development `:write` additionally permits
Linux tmpfs/overlay and local macOS APFS/HFS if structural capabilities pass.

macOS checks `fgetattrlist(ATTR_VOL_CAPABILITIES)` for `RENAME_EXCL` support and
publishes through fd-relative `renameatx_np(..., RENAME_EXCL)`. Its development
`:write` path uses the required structural fsync barriers. Strict macOS `:sync`
is rejected before storage creation; F_FULLFSYNC is not implemented/claimed.

Every mutation checks pinned paths and lock identity before and after the
operation. Symlinks, hard-linked required files, inode substitution, unexpected
extent, uncertain close, syscall errors and lost replies prevent success.
Acquisition syncs each parent in the absolute ancestor chain, including existing
entries that could have survived an interrupted earlier mkdir/sync operation.
Read-only path rechecks do not repeat those barriers.
Healthy shutdown confirms descriptor release before returning. A crashed or
blocked helper may delay a new owner's lock acquisition, but cannot justify a
concurrent writer or automatic uncertain-mutation retry.
