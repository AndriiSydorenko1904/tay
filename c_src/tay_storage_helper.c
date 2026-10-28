/* Tay filesystem Port, protocol v1. No checksums, events, or repair code. */
#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/statvfs.h>
#ifdef __linux__
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <linux/fs.h>
#else
#include <sys/mount.h>
#include <sys/attr.h>
#endif
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>

#define PROTOCOL_VERSION 1u
#define RECORD_PAYLOAD_MAX_BYTES 16777216u
#define RECORD_OVERHEAD_BYTES 28u
#define IO_BODY_MAX (RECORD_PAYLOAD_MAX_BYTES + RECORD_OVERHEAD_BYTES)
#define PACKET_METADATA_ALLOWANCE 8192u
#define PACKET_MAX (IO_BODY_MAX + PACKET_METADATA_ALLOWANCE)
#define SEGMENT_MAX_BYTES 1073741824ull
#define SEGMENT_HEADER_BYTES 44u
#define SEGMENT_FOOTER_BYTES 64u
#define AUTHORITY_METADATA_BYTES 28u
#define CURRENT_METADATA_BYTES 76u
#define WRITE_REQUEST_PREFIX_BYTES 9u
#define PACKET_LENGTH_BYTES 4u
#define PROTOCOL_VERSION_BYTES 1u
#define OPERATION_CODE_BYTES 1u
#define REQUEST_ID_BYTES 8u
#define ERROR_FLAG_BYTES 1u
#define ERROR_CODE_BYTES 4u
#define KNOWN_WRITTEN_BYTES 8u
#define REQUEST_HEADER_BYTES \
  (PROTOCOL_VERSION_BYTES + OPERATION_CODE_BYTES + REQUEST_ID_BYTES)
#define REPLY_HEADER_BYTES \
  (REQUEST_HEADER_BYTES + ERROR_FLAG_BYTES + ERROR_CODE_BYTES + KNOWN_WRITTEN_BYTES)
#define FRAMED_REPLY_HEADER_BYTES (PACKET_LENGTH_BYTES + REPLY_HEADER_BYTES)
#define REPLY_VERSION_OFFSET PACKET_LENGTH_BYTES
#define REPLY_OPERATION_OFFSET (REPLY_VERSION_OFFSET + PROTOCOL_VERSION_BYTES)
#define REPLY_REQUEST_ID_OFFSET (REPLY_OPERATION_OFFSET + OPERATION_CODE_BYTES)
#define REPLY_ERROR_FLAG_OFFSET (REPLY_REQUEST_ID_OFFSET + REQUEST_ID_BYTES)
#define REPLY_ERROR_CODE_OFFSET (REPLY_ERROR_FLAG_OFFSET + ERROR_FLAG_BYTES)
#define REPLY_KNOWN_WRITTEN_OFFSET (REPLY_ERROR_CODE_OFFSET + ERROR_CODE_BYTES)
/* Keep small requests cheap, then grow geometrically up to the protocol limit. */
#define INITIAL_PACKET_CAPACITY_BYTES 4096u
#define PACKET_CAPACITY_GROWTH_FACTOR 2u
#define FILE_IDENTITY_PAIR_BYTES 32u
#define RECLAIM_BASE_BYTES (CURRENT_METADATA_BYTES + 1u)
#define SEGMENT_ID_DIGITS 20u
#define HEX_ID_DIGITS 32u
#define TEMP_FILE_SUFFIX ".tmp"
#define TEMP_NONCE_BYTES (HEX_ID_DIGITS + sizeof(TEMP_FILE_SUFFIX) - 1u)
#define SEGMENT_EXTENSION ".tay"
#define STRING_BYTES(value) (sizeof(value) - 1u)
#define V2_MARKER_STAGE_PREFIX ".tay-v2-marker-"
#define CURRENT_STAGE_PREFIX ".tay-current-"
#define SEGMENT_STAGE_PREFIX ".tay-new-"
#define NANOSECONDS_PER_SECOND 1000000000ull
#define READBACK_VERIFY_CHUNK_BYTES 1048576u

enum filesystem_magic {
  FS_EXT = 0xEF53u,
  FS_XFS = 0x58465342u,
  FS_BTRFS = 0x9123683Eu,
  FS_TMPFS = 0x01021994u,
  FS_OVERLAY = 0x794c7630u
};

enum { ACQUIRE=1, LIST=2, MKDIR_SEGMENTS=3, OPEN_READ=4, READ_AT=5,
  CLOSE_READ=6, CREATE_STAGE=7, OPEN_ACTIVE=8, WRITE_AT=9, SYNC_FILE=10,
  CLOSE_WRITE=11, PUBLISH=12, SYNC_DIR=13, CHECK=14, INFO=15,
  SYNC_READ=16, SHUTDOWN=17, ACQUIRE_EXISTING=18, ENABLE_MUTATIONS=19,
  COLD_TARGET_OPEN=20, COLD_STAGE_CREATE=21, COLD_OPEN_WRITE=22,
  COLD_SYNC_STAGING=23, COLD_PUBLISH=24, COLD_SYNC_CATALOG=25,
  COLD_CHECK=26, COLD_SOURCE=27, COLD_LIST=28,
  V2_SELECT=29, V2_BEGIN=30, V2_PUBLISH_EPOCH=31,
  V2_PUBLISH_CURRENT=33, V2_SPACE=34,
  V2_RECLAIM=37, ACQUIRE_IF_MISSING=38, V2_ABORT=39,
  FAULT=240 };

/* Fault-site values are part of the test protocol. Keep their numeric values
 * stable even though they are not production request opcodes. */
enum fault_site {
  FAULT_WALK_ROOT_SYNC=241,
  FAULT_PROMOTE_LOCK_SYNC=242,
  FAULT_PROMOTE_ROOT_SYNC=243,
  FAULT_PROMOTE_SEGMENTS_SYNC=244,
  FAULT_EPOCHS_CREATE_SYNC=245,
  FAULT_CANDIDATE_PARENT_SYNC=246,
  FAULT_CANDIDATE_SEGMENTS_CREATE_SYNC=247,
  FAULT_CANDIDATE_SEGMENTS_SYNC=248,
  FAULT_CANDIDATE_SYNC=249,
  FAULT_EPOCH_PUBLISH_SYNC=250,
  FAULT_CURRENT_SYNC=253,
  FAULT_SEGMENT_UNLINK=258,
  FAULT_SEGMENT_UNLINK_SYNC=259,
  FAULT_SEGMENTS_RMDIR=260,
  FAULT_SEGMENTS_RMDIR_SYNC=261,
  FAULT_MANIFEST_UNLINK=262,
  FAULT_MANIFEST_UNLINK_SYNC=263,
  FAULT_EPOCH_RMDIR=264,
  FAULT_EPOCH_RMDIR_SYNC=265
};

/* Frozen test-protocol values shared with Tay.Storage.Native. */
enum fault_action {
  FAULT_ERROR_BEFORE_CALL=1,
  FAULT_SHORT_IO=2,
  FAULT_HELPER_CRASH_AFTER_CALL=3,
  FAULT_DROP_REPLY=4,
  FAULT_HELPER_CRASH_BEFORE_CALL=5,
  FAULT_LOSE_LOCK=6,
  FAULT_INVALID_REPLY_ID=7,
  FAULT_SYSCALL_ERROR_AFTER_CALL=8,
  FAULT_OWNER_VM_CRASH_AFTER_CALL=9,
  FAULT_OWNER_VM_CRASH_BEFORE_CALL=10
};

/* Values are exposed by diagnostics and therefore remain wire-stable. */
enum write_kind {
  WRITE_NONE=0,
  WRITE_SEGMENT=1,
  WRITE_SEGMENT_HEADER_STAGE=2,
  WRITE_COLD_COPY=4,
  WRITE_CURRENT_STAGE=5,
  WRITE_STORE_V2_STAGE=6
};

enum storage_scope {
  SCOPE_ROOT=0,
  SCOPE_SEGMENTS=1,
  SCOPE_COLD_VERIFY=2,
  SCOPE_EPOCHS=3,
  SCOPE_CANDIDATE=4,
  SCOPE_CANDIDATE_SEGMENTS=5,
  SCOPE_EPOCH=6
};

enum cold_scope {
  COLD_SCOPE_STAGE_ROOT=0,
  COLD_SCOPE_STAGE_SEGMENTS=1,
  COLD_SCOPE_CATALOG=2,
  COLD_SCOPE_VERIFY=3
};

enum helper_exit_status {
  HELPER_EXIT_CRASH_AFTER_CALL=93,
  HELPER_EXIT_CLOSE_FAILURE=94,
  HELPER_EXIT_CRASH_BEFORE_CALL=95,
  HELPER_EXIT_OWNER_VM_CRASH=96,
  HELPER_EXIT_INTERNAL_BOUNDS=97
};
/* The helper owns one source store. segments_parent_fd is a borrowed alias
 * of root_fd or epoch_fd and must never be closed independently. */
struct store_state {
  int root_fd, segments_fd, lock_fd, read_fd, write_fd;
  int epochs_fd, epoch_fd, segments_parent_fd;
  char segments_name[256], epoch_name[256], root_path[PATH_MAX];
  char write_name[256], read_name[256];
  int write_scope, write_kind, read_scope, poisoned, acquired;
  struct stat read_identity, write_identity;
  int strict_mode, validated_fs, root_created, inspection_only;
  uint64_t filesystem_type, known_written;
  uint32_t ancestor_syncs, directory_limit;
};
static struct store_state store = {
  .root_fd=-1, .segments_fd=-1, .lock_fd=-1, .read_fd=-1, .write_fd=-1,
  .epochs_fd=-1, .epoch_fd=-1, .segments_parent_fd=-1,
  .segments_name="segments", .directory_limit=UINT32_MAX
};

/* Candidate descriptors are independent of the selected source epoch. */
struct candidate_state {
  int write_fd, fd, segments_fd;
  int write_scope, write_kind;
  char name[256], write_name[256];
  struct stat write_identity;
};
static struct candidate_state pending_epoch = {
  .write_fd=-1, .fd=-1, .segments_fd=-1
};

/* Cold-copy targets own a source-independent tree. Parent descriptors borrow
 * the final entry of each chain; cold_chain_close is their sole closer. */
struct cold_chain { int *fds; size_t count, capacity; };
struct cold_copy_state {
  int target, source;
  int parent_fd, catalog_parent_fd, verify_parent_fd;
  int stage_fd, stage_epochs_fd, stage_epoch_fd;
  int stage_segments_fd, lock_fd;
  struct cold_chain parent_chain, catalog_chain, verify_chain;
  char parent_path[PATH_MAX], catalog_parent_path[PATH_MAX];
  char verify_parent_path[PATH_MAX];
  char target_name[256], staging_name[256], epoch_name[256];
  char catalog_name[256], verify_name[256];
  struct stat source_root, source_segments, stage_identity;
  struct stat stage_epochs_identity, stage_epoch_identity;
  struct stat stage_segments_identity, lock_identity;
  int has_verify, stage_created, published;
};
static struct cold_copy_state cold = {
  .parent_fd=-1, .catalog_parent_fd=-1, .verify_parent_fd=-1,
  .stage_fd=-1, .stage_epochs_fd=-1, .stage_epoch_fd=-1,
  .stage_segments_fd=-1, .lock_fd=-1
};
static int list_directory(void);

static const unsigned char *input;
static size_t input_n, pos;
static unsigned char output[PACKET_MAX];
static size_t output_n;

#ifdef TAY_TEST_FAULTS
static void kill_owner_vm(void) {
  pid_t owner=getppid();
  if (owner>1) kill(owner,SIGKILL);
  _exit(HELPER_EXIT_OWNER_VM_CRASH);
}

static int fault_op, fault_n, fault_action, fault_errno;
static uint64_t fault_short;
static int fault_now;
#endif

static int promotion_sync(int fd, unsigned target) {
#ifdef TAY_TEST_FAULTS
  int hit=fault_op==(int)target && fault_n>0 && --fault_n==0;
  if (hit) {
    fault_now=1;
    if (fault_action==FAULT_HELPER_CRASH_BEFORE_CALL) _exit(HELPER_EXIT_CRASH_BEFORE_CALL);
    if (fault_action==FAULT_OWNER_VM_CRASH_BEFORE_CALL) kill_owner_vm();
    if (fault_action==FAULT_ERROR_BEFORE_CALL || fault_action==FAULT_SYSCALL_ERROR_AFTER_CALL) {
      errno=fault_errno?fault_errno:EIO; return -1;
    }
  }
#else
  (void)target;
#endif
  int result=fsync(fd);
#ifdef TAY_TEST_FAULTS
  if (hit && fault_action==FAULT_HELPER_CRASH_AFTER_CALL) _exit(HELPER_EXIT_CRASH_AFTER_CALL);
  if (hit && fault_action==FAULT_OWNER_VM_CRASH_AFTER_CALL) kill_owner_vm();
#endif
  return result;
}

/* Reclamation is resumable only if an interruption at each unlink can be
 * distinguished from one at the subsequent parent-directory sync. */
static int reclamation_unlink(int fd,const char *name,int flags,unsigned target) {
#ifdef TAY_TEST_FAULTS
  int hit=fault_op==(int)target && fault_n>0 && --fault_n==0;
  if (hit) {
    fault_now=1;
    if (fault_action==FAULT_HELPER_CRASH_BEFORE_CALL) _exit(HELPER_EXIT_CRASH_BEFORE_CALL);
    if (fault_action==FAULT_OWNER_VM_CRASH_BEFORE_CALL) kill_owner_vm();
    if (fault_action==FAULT_ERROR_BEFORE_CALL || fault_action==FAULT_SYSCALL_ERROR_AFTER_CALL) {
      errno=fault_errno?fault_errno:EIO; return -1;
    }
  }
#else
  (void)target;
#endif
  int result=unlinkat(fd,name,flags);
#ifdef TAY_TEST_FAULTS
  if (hit && fault_action==FAULT_HELPER_CRASH_AFTER_CALL) _exit(HELPER_EXIT_CRASH_AFTER_CALL);
  if (hit && fault_action==FAULT_OWNER_VM_CRASH_AFTER_CALL) kill_owner_vm();
#endif
  return result;
}

static int need(size_t n) { return n <= input_n-pos; }
static uint64_t number(size_t n) {
  uint64_t v=0; for (size_t i=0;i<n;i++) v=(v<<8)|input[pos++]; return v;
}
static void encode_big_endian(unsigned char *destination, uint64_t value, size_t width) {
  if (width>sizeof(value)) _exit(HELPER_EXIT_INTERNAL_BOUNDS);
  for (size_t i=0;i<width;i++)
    destination[i]=(unsigned char)(value>>((width-1u-i)*8));
}
static void put(uint64_t n, size_t width) {
  /* A violated bound is an internal protocol-construction bug. Never permit it
   * to become memory corruption or a malformed successful reply. */
  if (width>sizeof(n) || width>sizeof(output)-output_n) _exit(HELPER_EXIT_INTERNAL_BOUNDS);
  for (size_t i=width;i>0;i--) output[output_n++]=(unsigned char)(n>>((i-1)*8));
}
static int string(char *dst, size_t cap) {
  if (!need(2)) return EPROTO;
  size_t n=(size_t)number(2);
  if (!need(n) || n==0 || n>=cap || memchr(input+pos,0,n)) return EPROTO;
  memcpy(dst,input+pos,n); dst[n]=0; pos+=n; return 0;
}
static int basename_ok(const char *s) {
  return *s && !strchr(s,'/') && strcmp(s,".") && strcmp(s,"..");
}
static int scope_fd(int scope) {
  if (scope==SCOPE_ROOT) return store.root_fd;
  if (scope==SCOPE_SEGMENTS) return store.segments_fd;
  if (scope==SCOPE_EPOCHS) return store.epochs_fd;
  if (scope==SCOPE_CANDIDATE) return pending_epoch.fd;
  if (scope==SCOPE_CANDIDATE_SEGMENTS) return pending_epoch.segments_fd;
  if (scope==SCOPE_EPOCH) return store.epoch_fd;
  return cold.target && scope==SCOPE_COLD_VERIFY ? cold.verify_parent_fd : -1;
}
static int same(const struct stat *a,const struct stat *b) {
  return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static void close_owned_fd(int *fd) {
  int owned=*fd;
  *fd=-1;
  if (owned>=0) (void)close(owned);
}
static int release_owned_fd(int *fd) {
  int owned=*fd;
  *fd=-1;
  return owned>=0 && close(owned)<0?errno:0;
}
static uint64_t time_ns(const struct timespec *time) {
  return (uint64_t)time->tv_sec*NANOSECONDS_PER_SECOND+(uint64_t)time->tv_nsec;
}
static unsigned int type_of(mode_t mode) {
  return S_ISREG(mode)?1:S_ISDIR(mode)?2:S_ISLNK(mode)?3:4;
}
static void stat_out(const struct stat *s) {
  put((uint64_t)s->st_size,8); put((uint64_t)s->st_dev,8); put((uint64_t)s->st_ino,8);
  put((uint64_t)s->st_nlink,8); put(type_of(s->st_mode),1); put((uint32_t)s->st_mode,4);
  /* The ordinary storage protocol has a frozen 37-byte identity.  Cold-copy
   * sessions opt into timestamps so their source mutation check is stronger
   * without changing recovery's existing identity contract. */
  if (!cold.source && !cold.target) return;
#ifdef __APPLE__
  put(time_ns(&s->st_mtimespec),8); put(time_ns(&s->st_ctimespec),8);
#else
  put(time_ns(&s->st_mtim),8); put(time_ns(&s->st_ctim),8);
#endif
}
static int checked_regular(int fd, int directory, const char *name, struct stat *s) {
  struct stat path;
  if (fstat(fd,s)<0 || fstatat(directory,name,&path,AT_SYMLINK_NOFOLLOW)<0) return errno;
  if (!S_ISREG(s->st_mode) || !S_ISREG(path.st_mode)) return EINVAL;
  if (s->st_nlink!=1 || path.st_nlink!=1) return EMLINK;
  return same(s,&path)?0:ESTALE;
}
static int checked_directory(int fd, int directory, const char *name) {
  struct stat pinned,path;
  if (fstat(fd,&pinned)<0 || fstatat(directory,name,&path,AT_SYMLINK_NOFOLLOW)<0) return errno;
  if (!S_ISDIR(pinned.st_mode) || !S_ISDIR(path.st_mode)) return EINVAL;
  return same(&pinned,&path)?0:ESTALE;
}
static int no_replace_between(int from,const char *src,int to,const char *dst) {
#ifdef __linux__
  return (int)syscall(SYS_renameat2,from,src,to,dst,RENAME_NOREPLACE);
#elif defined(__APPLE__)
  return renameatx_np(from,src,to,dst,RENAME_EXCL);
#else
  (void)from; (void)src; (void)to; (void)dst; errno=ENOTSUP; return -1;
#endif
}
static int no_replace(int fd,const char *src,const char *dst) {
  return no_replace_between(fd,src,fd,dst);
}
static int rename_capability(void) {
#ifdef __APPLE__
  struct attrlist attrs;
  memset(&attrs,0,sizeof(attrs)); attrs.bitmapcount=ATTR_BIT_MAP_COUNT;
  attrs.volattr=ATTR_VOL_INFO|ATTR_VOL_CAPABILITIES;
  struct { uint32_t size; vol_capabilities_attr_t caps; } result;
  memset(&result,0,sizeof(result));
  if (fgetattrlist(store.root_fd,&attrs,&result,sizeof(result),0)<0) return errno;
  unsigned i=VOL_CAPABILITIES_INTERFACES;
  return (result.caps.valid[i] & VOL_CAP_INT_RENAME_EXCL) &&
    (result.caps.capabilities[i] & VOL_CAP_INT_RENAME_EXCL) ? 0 : ENOTSUP;
#else
  if (no_replace(store.root_fd,".tay-owner.lock",".tay-owner.lock")==0) return ENOTSUP;
  return errno==EEXIST?0:errno;
#endif
}
static int filesystem(int fd) {
  struct statfs s;
  if (fstatfs(fd,&s)<0) return errno;
#ifdef __linux__
  uint64_t t=(uint64_t)(unsigned long)s.f_type;
  store.filesystem_type=t;
  int persistent=(t==FS_EXT || t==FS_XFS || t==FS_BTRFS);
  int development=persistent || t==FS_TMPFS || t==FS_OVERLAY;
  if (store.strict_mode) return store.validated_fs && persistent ? 0 : ENOTSUP;
  return development ? 0 : ENOTSUP;
#elif defined(__APPLE__)
  store.filesystem_type=0;
  if (store.strict_mode) return ENOTSUP;
  return (s.f_flags & MNT_LOCAL) && (!strcmp(s.f_fstypename,"apfs") || !strcmp(s.f_fstypename,"hfs")) ? 0 : ENOTSUP;
#else
  return ENOTSUP;
#endif
}

static void cold_chain_close(struct cold_chain *chain) {
  if (chain->fds) {
    for (size_t i=0;i<chain->count;i++) if (chain->fds[i]>=0) close(chain->fds[i]);
    free(chain->fds);
  }
  chain->fds=NULL; chain->count=0; chain->capacity=0;
}
static void abandon_cold_target(void) {
  cold_chain_close(&cold.parent_chain);
  cold_chain_close(&cold.catalog_chain);
  cold_chain_close(&cold.verify_chain);
  cold.parent_fd=cold.catalog_parent_fd=cold.verify_parent_fd=-1;
  cold.target=0;
}
static void shutdown_owned_handles(void) {
  int *descriptors[] = {
    &store.write_fd, &pending_epoch.write_fd, &store.read_fd, &store.segments_fd, &pending_epoch.segments_fd, &pending_epoch.fd, &store.epoch_fd, &store.epochs_fd, &store.root_fd, &store.lock_fd, &cold.stage_fd, &cold.stage_epochs_fd, &cold.stage_epoch_fd, &cold.stage_segments_fd, &cold.lock_fd
  };
  for (size_t i=0; i<sizeof(descriptors)/sizeof(descriptors[0]); i++) {
    if (release_owned_fd(descriptors[i])) _exit(HELPER_EXIT_CLOSE_FAILURE);
  }
  store.segments_parent_fd=-1;
  store.acquired=0;
  abandon_cold_target();
}

static int cold_chain_push(struct cold_chain *chain,int fd) {
  if (chain->count==chain->capacity) {
    size_t capacity=chain->capacity?chain->capacity*2u:8u;
    if (capacity>SIZE_MAX/sizeof(int)) return ENOMEM;
    int *next=realloc(chain->fds,capacity*sizeof(int));
    if (!next) return ENOMEM;
    chain->fds=next; chain->capacity=capacity;
  }
  chain->fds[chain->count++]=fd; return 0;
}
/* Pin an existing absolute directory path from /. Path components are opened
 * descriptor-relatively with O_NOFOLLOW; the retained chain permits an exact
 * ancestor revalidation before every destination mutation/publication. */
static int cold_open_chain(const char *absolute,struct cold_chain *chain) {
  if (!absolute || absolute[0]!='/') return EINVAL;
  char path[PATH_MAX]; size_t n=strlen(absolute);
  if (!n || n>=sizeof(path)) return ENAMETOOLONG;
  memcpy(path,absolute,n+1);
  int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  if (fd<0) return errno;
  int e=cold_chain_push(chain,fd);
  if (e) { close(fd); return e; }
  /* / is a valid already-existing parent.  Keeping the root descriptor gives
   * it the same identity revalidation as every longer ancestor chain. */
  if (!strcmp(absolute,"/")) return 0;
  char *save=NULL,*part=strtok_r(path,"/",&save);
  while (part) {
    if (!basename_ok(part)) { cold_chain_close(chain); return EINVAL; }
    int child=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (child<0) { e=errno; cold_chain_close(chain); return e; }
    e=cold_chain_push(chain,child);
    if (e) { close(child); cold_chain_close(chain); return e; }
    fd=child; part=strtok_r(NULL,"/",&save);
  }
  return 0;
}
static int cold_chain_matches(const char *absolute,const struct cold_chain *original) {
  struct cold_chain current={0};
  int e=cold_open_chain(absolute,&current);
  if (e) return e;
  if (current.count!=original->count) e=ESTALE;
  for (size_t i=0;!e && i<current.count;i++) {
    struct stat a,b;
    if (fstat(current.fds[i],&a)<0 || fstat(original->fds[i],&b)<0) e=errno;
    else if (!S_ISDIR(a.st_mode) || !same(&a,&b)) e=ESTALE;
  }
  cold_chain_close(&current); return e;
}
static int cold_chain_aliases_source(const struct cold_chain *chain) {
  for (size_t i=0;i<chain->count;i++) {
    struct stat current;
    if (fstat(chain->fds[i],&current)<0) return errno;
    if (same(&current,&cold.source_root) || same(&current,&cold.source_segments)) return EBUSY;
  }
  return 0;
}
static int absent_at(int parent,const char *name) {
  struct stat found;
  if (fstatat(parent,name,&found,AT_SYMLINK_NOFOLLOW)==0) return EEXIST;
  return errno==ENOENT?0:errno;
}
static int cold_check_paths(void) {
  if (!cold.target || cold.parent_fd<0 || cold.catalog_parent_fd<0) return EBADF;
  int e=cold_chain_matches(cold.parent_path,&cold.parent_chain); if (e) return e;
  e=cold_chain_matches(cold.catalog_parent_path,&cold.catalog_chain); if (e) return e;
  if (cold.has_verify) {
    e=cold_chain_matches(cold.verify_parent_path,&cold.verify_chain); if (e) return e;
  }
  e=cold_chain_aliases_source(&cold.parent_chain); if (e) return e;
  e=cold_chain_aliases_source(&cold.catalog_chain); if (e) return e;
  if (cold.has_verify) { e=cold_chain_aliases_source(&cold.verify_chain); if (e) return e; }
  if (cold.stage_created) {
    struct stat opened,named;
    if (fstat(cold.stage_fd,&opened)<0) return errno;
    if (fstatat(cold.parent_fd,cold.published?cold.target_name:cold.staging_name,&named,AT_SYMLINK_NOFOLLOW)<0) return errno;
    if (!S_ISDIR(opened.st_mode) || !same(&opened,&cold.stage_identity) || !same(&opened,&named)) return ESTALE;
    if (fstat(cold.stage_epochs_fd,&opened)<0) return errno;
    if (fstatat(cold.stage_fd,"epochs",&named,AT_SYMLINK_NOFOLLOW)<0) return errno;
    if (!S_ISDIR(opened.st_mode) || !same(&opened,&cold.stage_epochs_identity) || !same(&opened,&named)) return ESTALE;
    if (fstat(cold.stage_epoch_fd,&opened)<0) return errno;
    if (fstatat(cold.stage_epochs_fd,cold.epoch_name,&named,AT_SYMLINK_NOFOLLOW)<0) return errno;
    if (!S_ISDIR(opened.st_mode) || !same(&opened,&cold.stage_epoch_identity) || !same(&opened,&named)) return ESTALE;
    if (fstat(cold.stage_segments_fd,&opened)<0) return errno;
    if (fstatat(cold.stage_epoch_fd,"segments",&named,AT_SYMLINK_NOFOLLOW)<0) return errno;
    if (!S_ISDIR(opened.st_mode) || !same(&opened,&cold.stage_segments_identity) || !same(&opened,&named)) return ESTALE;
    if (cold.lock_fd>=0) {
      e=checked_regular(cold.lock_fd,cold.stage_fd,".tay-owner.lock",&opened);
      if (e) return e;
      if (!same(&opened,&cold.lock_identity)) return ESTALE;
    }
  }
  return 0;
}
/* Walk from a pinned / FD. Never follow a symlink or use cwd resolution. */
static int walk_root(int create, int *result, int *created) {
  char path[PATH_MAX]; memcpy(path,store.root_path,strlen(store.root_path)+1);
  if (path[0]!='/' || !strcmp(path,"/")) return EINVAL;
  int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  if (fd<0) return errno;
  char *save=NULL, *part=strtok_r(path,"/",&save);
  *created=0;
  int made=0;
  while (part) {
    char *next=strtok_r(NULL,"/",&save);
    if (!basename_ok(part)) { close(fd); return EINVAL; }
    int child=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (child<0 && errno==ENOENT && (create==1 || create==3)) {
      int e=filesystem(fd);
      if (e) { close(fd); return e; }
      if (mkdirat(fd,part,0700)<0) { e=errno; close(fd); return e; }
      made=1;
      if (!next) *created=1;
      child=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    }
    if (child<0) { int e=errno; close(fd); return e; }
    /* Existing entries can belong to an interrupted earlier mkdir/fsync. */
    if (create && (create!=3 || made)) {
      int synced=create==2?promotion_sync(fd,FAULT_WALK_ROOT_SYNC):fsync(fd);
      if (synced<0) { int e=errno; close(child); close(fd); return e; }
      store.ancestor_syncs++;
    }
    if (close(fd)<0) { int e=errno; close(child); return e; }
    fd=child; part=next;
  }
  *result=fd; return 0;
}
static int validate_paths(void) {
  if (store.root_fd<0 || store.lock_fd<0) return EBADF;
  int current=-1, created=0;
  int e=walk_root(0,&current,&created);
  if (e) return e;
  struct stat root, path, lock;
  if (fstat(store.root_fd,&root)<0 || fstat(current,&path)<0) { e=errno; close(current); return e; }
  if (close(current)<0) return errno;
  if (!same(&root,&path)) return ESTALE;
  e=checked_regular(store.lock_fd,store.root_fd,".tay-owner.lock",&lock);
  if (e) return e;
  if (store.epochs_fd>=0) {
    e=checked_directory(store.epochs_fd,store.root_fd,"epochs"); if (e) return e;
  }
  if (store.epoch_fd>=0) {
    e=checked_directory(store.epoch_fd,store.epochs_fd,store.epoch_name); if (e) return e;
  }
  if (pending_epoch.fd>=0) {
    e=checked_directory(pending_epoch.fd,store.epochs_fd,pending_epoch.name); if (e) return e;
  }
  if (pending_epoch.segments_fd>=0) {
    e=checked_directory(pending_epoch.segments_fd,pending_epoch.fd,"segments"); if (e) return e;
  }
  if (store.segments_fd>=0) {
    e=checked_directory(store.segments_fd,store.segments_parent_fd,store.segments_name);
    if (e) return e;
  }
  if (store.write_fd>=0) {
    struct stat now;
    e=checked_regular(store.write_fd,scope_fd(store.write_scope),store.write_name,&now);
    if (e) return e;
    if (!same(&now,&store.write_identity) || now.st_size!=store.write_identity.st_size) return ESTALE;
  }
  if (pending_epoch.write_fd>=0) {
    struct stat now;
    e=checked_regular(pending_epoch.write_fd,scope_fd(pending_epoch.write_scope),pending_epoch.write_name,&now);
    if (e) return e;
    if (!same(&now,&pending_epoch.write_identity) || now.st_size!=pending_epoch.write_identity.st_size) return ESTALE;
  }
  return 0;
}
static int check_paths(void) {
  return store.acquired?validate_paths():EBADF;
}

static void abandon_acquisition(void) {
  close_owned_fd(&store.segments_fd);
  close_owned_fd(&store.lock_fd);
  close_owned_fd(&store.root_fd);
  store.segments_parent_fd=-1;
  store.acquired=0;
  store.inspection_only=0;
}
static int open_segments(void) {
  if (store.segments_fd>=0) return 0;
  store.segments_fd=openat(store.root_fd,"segments",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (store.segments_fd<0) return errno;
  int e=filesystem(store.segments_fd);
  if (e) { close(store.segments_fd); store.segments_fd=-1; }
  else { store.segments_parent_fd=store.root_fd; strcpy(store.segments_name,"segments"); }
  return e;
}
static int canonical(const char *name) {
  if (strlen(name)!=SEGMENT_ID_DIGITS+STRING_BYTES(SEGMENT_EXTENSION) ||
      strcmp(name+SEGMENT_ID_DIGITS,SEGMENT_EXTENSION)) return 0;
  uint64_t id=0;
  for (size_t i=0;i<SEGMENT_ID_DIGITS;i++) {
    if (name[i]<'0'||name[i]>'9') return 0;
    unsigned d=(unsigned)(name[i]-'0');
    if (id>(UINT64_MAX-d)/10) return 0;
    id=id*10+d;
  }
  return id!=0;
}
static int nonce(const char *s) {
  for (size_t i=0;i<HEX_ID_DIGITS;i++)
    if (!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f'))) return 0;
  return !strcmp(s+HEX_ID_DIGITS,TEMP_FILE_SUFFIX);
}
static int hex32(const char *s) {
  if (strlen(s)!=HEX_ID_DIGITS) return 0;
  for (size_t i=0;i<HEX_ID_DIGITS;i++)
    if (!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f'))) return 0;
  return 1;
}
static int epoch_name_ok(const char *s) { return !strncmp(s,"e-",2) && hex32(s+2); }
static int candidate_name_ok(const char *s) {
  return !strncmp(s,".tay-candidate-",15) && nonce(s+15);
}
static int stage_kind(int scope,const char *name) {
  if (scope==SCOPE_ROOT &&
      !strncmp(name,V2_MARKER_STAGE_PREFIX,STRING_BYTES(V2_MARKER_STAGE_PREFIX)) &&
      nonce(name+STRING_BYTES(V2_MARKER_STAGE_PREFIX)))
    return WRITE_STORE_V2_STAGE;
  if (scope==SCOPE_ROOT &&
      !strncmp(name,CURRENT_STAGE_PREFIX,STRING_BYTES(CURRENT_STAGE_PREFIX)) &&
      nonce(name+STRING_BYTES(CURRENT_STAGE_PREFIX)))
    return WRITE_CURRENT_STAGE;
  size_t segment_stage_separator=STRING_BYTES(SEGMENT_STAGE_PREFIX)+SEGMENT_ID_DIGITS;
  if (scope==SCOPE_SEGMENTS &&
      strlen(name)==segment_stage_separator+1u+TEMP_NONCE_BYTES &&
      !strncmp(name,SEGMENT_STAGE_PREFIX,STRING_BYTES(SEGMENT_STAGE_PREFIX)) &&
      name[segment_stage_separator]=='-' && nonce(name+segment_stage_separator+1u)) {
    char canon[SEGMENT_ID_DIGITS+sizeof(SEGMENT_EXTENSION)];
    memcpy(canon,name+STRING_BYTES(SEGMENT_STAGE_PREFIX),SEGMENT_ID_DIGITS);
    memcpy(canon+SEGMENT_ID_DIGITS,SEGMENT_EXTENSION,sizeof(SEGMENT_EXTENSION));
    if (canonical(canon)) return WRITE_SEGMENT_HEADER_STAGE;
  }
  if (scope==SCOPE_CANDIDATE && !strcmp(name,"MANIFEST")) return WRITE_COLD_COPY;
  if (scope==SCOPE_CANDIDATE_SEGMENTS && canonical(name)) return WRITE_SEGMENT;
  return WRITE_NONE;
}

static size_t staged_write_size(int kind) {
  switch (kind) {
    case WRITE_SEGMENT_HEADER_STAGE: return SEGMENT_HEADER_BYTES;
    case WRITE_CURRENT_STAGE: return CURRENT_METADATA_BYTES;
    case WRITE_STORE_V2_STAGE: return AUTHORITY_METADATA_BYTES;
    default: return 0;
  }
}
static int acquire(int mode) {
  int existing=mode==1, if_missing=mode==2;
  if (store.acquired || !need(2)) return EPROTO;
  store.strict_mode=(int)number(1); store.validated_fs=(int)number(1);
  if (store.strict_mode>1 || store.validated_fs>1) return EINVAL;
  if (existing) {
    if (!need(4)) return EPROTO;
    store.directory_limit=(uint32_t)number(4);
    if (!store.directory_limit) return EINVAL;
  }
#ifndef __linux__
  if (store.strict_mode) return ENOTSUP;
#endif
  if (store.strict_mode && !store.validated_fs) return ENOTSUP;
  int e=string(store.root_path,sizeof(store.root_path));
  if (e || pos!=input_n) return e?e:EPROTO;
  if (store.strict_mode && (!strncmp(store.root_path,"/tmp/",5) || !strcmp(store.root_path,"/tmp") ||
      !strncmp(store.root_path,"/var/tmp/",9) || !strncmp(store.root_path,"/dev/shm/",9))) return ENOTSUP;
  e=walk_root(existing?0:if_missing?3:1,&store.root_fd,&store.root_created);
  if (e) return e;
  e=filesystem(store.root_fd); if (e) goto fail;
  int created=0;
  if (existing || (if_missing && !store.root_created)) {
    store.lock_fd=openat(store.root_fd,".tay-owner.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  } else {
    store.lock_fd=openat(store.root_fd,".tay-owner.lock",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (store.lock_fd>=0) created=1;
    else if (errno==EEXIST && !if_missing) store.lock_fd=openat(store.root_fd,".tay-owner.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC);
  }
  if (store.lock_fd<0) { e=errno; goto fail; }
  struct stat s;
  e=checked_regular(store.lock_fd,store.root_fd,".tay-owner.lock",&s); if (e) goto fail;
  if (flock(store.lock_fd,LOCK_EX|LOCK_NB)<0) { e=errno; goto fail; }
  store.inspection_only=existing || (if_missing && !store.root_created);
  if (!store.inspection_only) {
    e=rename_capability(); if (e) goto fail;
    if (fsync(store.root_fd)<0) { e=errno; goto fail; }
    if (created && fsync(store.lock_fd)<0) { e=errno; goto fail; }
    if (created && fsync(store.root_fd)<0) { e=errno; goto fail; }
  }
  e=open_segments(); if (e && e!=ENOENT) goto fail;
  e=validate_paths(); if (e) goto fail;
  store.acquired=1;
  put(store.root_created,1); put(store.filesystem_type,8); put((uint64_t)getpid(),8);
  return 0;

fail:
  abandon_acquisition();
  return e;
}
/* Promotion keeps every ownership FD. Mode 2 walks/syncs existing ancestors
 * without granting mkdir permission, even if an external path disappears. */
static int enable_mutations(void) {
  if (!store.inspection_only || store.read_fd>=0 || store.write_fd>=0) return EBUSY;
  int e=check_paths(); if (e) return e;
  e=filesystem(store.root_fd); if (e) return e;
  if (store.segments_fd<0) return ENOENT;
  e=filesystem(store.segments_fd); if (e) return e;
  e=rename_capability(); if (e) return e;
  int current=-1, created=0;
  e=walk_root(2,&current,&created); if (e) return e;
  struct stat pinned, now;
  if (fstat(store.root_fd,&pinned)<0 || fstat(current,&now)<0) e=errno;
  else if (!same(&pinned,&now)) e=ESTALE;
  if (close(current)<0 && !e) e=errno;
  if (e) return e;
  if (promotion_sync(store.lock_fd,FAULT_PROMOTE_LOCK_SYNC)<0 ||
      promotion_sync(store.root_fd,FAULT_PROMOTE_ROOT_SYNC)<0 ||
      promotion_sync(store.segments_fd,FAULT_PROMOTE_SEGMENTS_SYNC)<0) return errno;
  e=check_paths(); if (e) return e;
  store.inspection_only=0;
  return 0;
}

static int open_epochs(int create) {
  if (store.epochs_fd>=0) return checked_directory(store.epochs_fd,store.root_fd,"epochs");
  int created=0, next=-1;
  next=openat(store.root_fd,"epochs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (next<0 && errno==ENOENT && create) {
    if (mkdirat(store.root_fd,"epochs",0700)<0) return errno;
    created=1;
    next=openat(store.root_fd,"epochs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  }
  if (next<0) return errno;
  int e=checked_directory(next,store.root_fd,"epochs");
  if (!e) e=filesystem(next);
  if (!e && created && promotion_sync(store.root_fd,FAULT_EPOCHS_CREATE_SYNC)<0) e=errno;
  if (e) { close(next); return e; }
  store.epochs_fd=next;
  return 0;
}

static int v2_select(void) {
  char name[256];
  int e=string(name,sizeof(name));
  if (e || !epoch_name_ok(name) || store.read_fd>=0 || store.write_fd>=0 || pending_epoch.write_fd>=0)
    return e?e:EINVAL;
  e=open_epochs(0); if (e) return e;
  int next_epoch=openat(store.epochs_fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (next_epoch<0) return errno;
  e=checked_directory(next_epoch,store.epochs_fd,name);
  if (!e) e=filesystem(next_epoch);
  int next_segments=-1;
  if (!e) {
    next_segments=openat(next_epoch,"segments",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (next_segments<0) e=errno;
  }
  if (!e) e=checked_directory(next_segments,next_epoch,"segments");
  if (!e) e=filesystem(next_segments);
  if (e) { if (next_segments>=0) close(next_segments); close(next_epoch); return e; }
  e=release_owned_fd(&pending_epoch.segments_fd);
  int close_error=release_owned_fd(&pending_epoch.fd);
  if (!e) e=close_error;
  if (e) { close(next_segments); close(next_epoch); return e; }
  e=release_owned_fd(&store.segments_fd);
  close_error=release_owned_fd(&store.epoch_fd);
  if (!e) e=close_error;
  if (e) { close(next_segments); close(next_epoch); return e; }
  store.segments_fd=next_segments; store.epoch_fd=next_epoch; store.segments_parent_fd=store.epoch_fd;
  strcpy(store.segments_name,"segments"); strcpy(store.epoch_name,name);
  pending_epoch.name[0]=0;
  return check_paths();
}

static int v2_begin(void) {
  char name[256];
  int e=string(name,sizeof(name));
  if (e || !candidate_name_ok(name) || pending_epoch.fd>=0 || pending_epoch.write_fd>=0 || store.read_fd>=0)
    return e?e:EBUSY;
  e=open_epochs(1); if (e) return e;
  if (mkdirat(store.epochs_fd,name,0700)<0) return errno;
  int next_candidate=openat(store.epochs_fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (next_candidate<0) return errno;
  int next_segments=-1;
  e=checked_directory(next_candidate,store.epochs_fd,name);
  if (!e) e=filesystem(next_candidate);
  if (!e && promotion_sync(store.epochs_fd,FAULT_CANDIDATE_PARENT_SYNC)<0) e=errno;
  if (!e && mkdirat(next_candidate,"segments",0700)<0) e=errno;
  if (!e) {
    next_segments=openat(next_candidate,"segments",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (next_segments<0) e=errno;
  }
  if (!e) e=checked_directory(next_segments,next_candidate,"segments");
  if (!e) e=filesystem(next_segments);
  if (!e && promotion_sync(next_candidate,FAULT_CANDIDATE_SEGMENTS_CREATE_SYNC)<0) e=errno;
  if (e) {
    if (next_segments>=0) close(next_segments);
    close(next_candidate);
    return e;
  }
  pending_epoch.fd=next_candidate;
  pending_epoch.segments_fd=next_segments;
  strcpy(pending_epoch.name,name);
  e=check_paths();
  if (e) {
    close_owned_fd(&pending_epoch.segments_fd);
    close_owned_fd(&pending_epoch.fd);
    pending_epoch.name[0]=0;
  }
  return e;
}

static int release_candidate_handles(void) {
  int *descriptors[] = {&store.read_fd, &pending_epoch.write_fd,
    &pending_epoch.segments_fd, &pending_epoch.fd};
  int first_error=0;
  for (size_t i=0; i<sizeof(descriptors)/sizeof(descriptors[0]); i++) {
    int error=release_owned_fd(descriptors[i]);
    if (!first_error) first_error=error;
  }
  pending_epoch.write_kind=WRITE_NONE;
  pending_epoch.write_name[0]=0;
  pending_epoch.name[0]=0;
  return first_error;
}

static int v2_abort(void) {
  int error=release_candidate_handles();
  return error?error:check_paths();
}

static int v2_publish_epoch(void) {
  char name[256];
  int e=string(name,sizeof(name));
  if (e || !epoch_name_ok(name) || pending_epoch.fd<0 || store.write_fd>=0 ||
      pending_epoch.write_fd>=0 || store.read_fd>=0) return e?e:EINVAL;
  e=checked_directory(pending_epoch.fd,store.epochs_fd,pending_epoch.name); if (e) return e;
  if (promotion_sync(pending_epoch.segments_fd,FAULT_CANDIDATE_SEGMENTS_SYNC)<0 ||
      promotion_sync(pending_epoch.fd,FAULT_CANDIDATE_SYNC)<0) return errno;
  if (no_replace(store.epochs_fd,pending_epoch.name,name)<0) return errno;
  strcpy(pending_epoch.name,name);
  if (promotion_sync(store.epochs_fd,FAULT_EPOCH_PUBLISH_SYNC)<0) return errno;
  return checked_directory(pending_epoch.fd,store.epochs_fd,pending_epoch.name);
}

static int v2_publish_current(void) {
  char stage[256];
  int e=string(stage,sizeof(stage));
  if (e || stage_kind(SCOPE_ROOT,stage)!=WRITE_CURRENT_STAGE ||
      !need(FILE_IDENTITY_PAIR_BYTES) ||
      store.write_fd>=0 || pending_epoch.write_fd>=0)
    return e?e:EINVAL;
  uint64_t stage_dev=number(8),stage_ino=number(8),old_dev=number(8),old_ino=number(8);
  struct stat source,old,after;
  if (fstatat(store.root_fd,stage,&source,AT_SYMLINK_NOFOLLOW)<0) return errno;
  if (!S_ISREG(source.st_mode) || source.st_nlink!=1 ||
      source.st_size!=CURRENT_METADATA_BYTES ||
      (uint64_t)source.st_dev!=stage_dev || (uint64_t)source.st_ino!=stage_ino) return ESTALE;
  if (!old_dev && !old_ino) {
    e=absent_at(store.root_fd,"CURRENT"); if (e) return e;
    if (no_replace(store.root_fd,stage,"CURRENT")<0) return errno;
  } else {
    if (fstatat(store.root_fd,"CURRENT",&old,AT_SYMLINK_NOFOLLOW)<0) return errno;
    if (!S_ISREG(old.st_mode) || old.st_nlink!=1 || (uint64_t)old.st_dev!=old_dev ||
        (uint64_t)old.st_ino!=old_ino) return ESTALE;
    if (renameat(store.root_fd,stage,store.root_fd,"CURRENT")<0) return errno;
  }
  if (promotion_sync(store.root_fd,FAULT_CURRENT_SYNC)<0) return errno;
  if (fstatat(store.root_fd,"CURRENT",&after,AT_SYMLINK_NOFOLLOW)<0) return errno;
  return S_ISREG(after.st_mode) && after.st_nlink==1 && same(&source,&after) ? 0 : ESTALE;
}

static int v2_space(void) {
  struct statvfs info;
  if (fstatvfs(store.root_fd,&info)<0) return errno;
  if (info.f_frsize && info.f_bavail>UINT64_MAX/info.f_frsize) return EOVERFLOW;
  put((uint64_t)info.f_bavail*(uint64_t)info.f_frsize,8);
  return 0;
}

static int exact_metadata(int directory,const char *name,const unsigned char *expected,size_t n) {
  int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  if (fd<0) return errno;
  struct stat s;
  int e=checked_regular(fd,directory,name,&s);
  if (!e && (uint64_t)s.st_size!=n) e=ESTALE;
  unsigned char bytes[CURRENT_METADATA_BYTES];
  if (!e) {
    ssize_t got=pread(fd,bytes,n,0);
    if (got<0) e=errno;
    else if ((size_t)got!=n || memcmp(bytes,expected,n)) e=ESTALE;
  }
  if (close(fd)<0 && !e) e=errno;
  return e;
}

static int reclaim_segments(int directory,uint64_t *bytes) {
  int fd=openat(directory,"segments",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (fd<0) return errno==ENOENT?0:errno;
  int e=checked_directory(fd,directory,"segments");
  if (e) { close(fd); return e; }
  int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (copy<0) { e=errno; close(fd); return e; }
  DIR *dir=fdopendir(copy);
  if (!dir) { e=errno; close(copy); close(fd); return e; }
  struct dirent *ent; uint32_t count=0;
  errno=0;
  while ((ent=readdir(dir))) {
    if (!strcmp(ent->d_name,".") || !strcmp(ent->d_name,"..")) continue;
    struct stat s;
    if (++count>store.directory_limit) { e=EFBIG; break; }
    if (!canonical(ent->d_name) || fstatat(fd,ent->d_name,&s,AT_SYMLINK_NOFOLLOW)<0 ||
        !S_ISREG(s.st_mode) || s.st_nlink!=1) { e=EINVAL; break; }
    errno=0;
  }
  if (!e && errno) e=errno;
  if (closedir(dir)<0 && !e) e=errno;
  if (e) { close(fd); return e; }
  copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (copy<0) { e=errno; close(fd); return e; }
  dir=fdopendir(copy);
  if (!dir) { e=errno; close(copy); close(fd); return e; }
  errno=0;
  while ((ent=readdir(dir))) {
    if (!strcmp(ent->d_name,".") || !strcmp(ent->d_name,"..")) continue;
    struct stat s;
    if (fstatat(fd,ent->d_name,&s,AT_SYMLINK_NOFOLLOW)<0) { e=errno; break; }
    if (reclamation_unlink(fd,ent->d_name,0,FAULT_SEGMENT_UNLINK)<0 ||
        promotion_sync(fd,FAULT_SEGMENT_UNLINK_SYNC)<0) { e=errno; break; }
    *bytes+=(uint64_t)s.st_size;
    errno=0;
  }
  if (!e && errno) e=errno;
  if (closedir(dir)<0 && !e) e=errno;
  if (close(fd)<0 && !e) e=errno;
  if (e) return e;
  if (reclamation_unlink(directory,"segments",AT_REMOVEDIR,FAULT_SEGMENTS_RMDIR)<0 ||
      promotion_sync(directory,FAULT_SEGMENTS_RMDIR_SYNC)<0) return errno;
  return 0;
}

static int v2_reclaim(void) {
  char target[256];
  int e=string(target,sizeof(target));
  if (e || !need(RECLAIM_BASE_BYTES)) return e?e:EPROTO;
  if (!epoch_name_ok(target)) return EINVAL;
  const unsigned char *expected_current=input+pos; pos+=CURRENT_METADATA_BYTES;
  int has_intent=(int)number(1);
  if (has_intent || pos!=input_n) return EINVAL;
  e=exact_metadata(store.root_fd,"CURRENT",expected_current,CURRENT_METADATA_BYTES); if (e) return e;
  if (memcmp(expected_current,"TAYC\001\0\0\0",8)) return EINVAL;
  char current_name[35]="e-";
  static const char hex[]="0123456789abcdef";
  for (int i=0;i<16;i++) {
    current_name[2+i*2]=hex[expected_current[24+i]>>4];
    current_name[3+i*2]=hex[expected_current[24+i]&15];
  }
  current_name[34]=0;
  if (!strcmp(target,current_name)) return EBUSY;
  e=open_epochs(0); if (e) return e;
  int target_fd=openat(store.epochs_fd,target,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (target_fd<0 && errno!=ENOENT) return errno;
  uint64_t bytes=0;
  if (target_fd>=0) {
    e=checked_directory(target_fd,store.epochs_fd,target); if (e) { close(target_fd); return e; }
    int copy=openat(target_fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (copy<0) { e=errno; close(target_fd); return e; }
    DIR *dir=fdopendir(copy);
    if (!dir) { e=errno; close(copy); close(target_fd); return e; }
    struct dirent *ent; int manifest=0,segments_present=0; uint32_t count=0;
    errno=0;
    while ((ent=readdir(dir))) {
      if (!strcmp(ent->d_name,".") || !strcmp(ent->d_name,"..")) continue;
      if (++count>store.directory_limit) { e=EFBIG; break; }
      if (!strcmp(ent->d_name,"MANIFEST")) {
        struct stat s;
        if (fstatat(target_fd,"MANIFEST",&s,AT_SYMLINK_NOFOLLOW)<0 ||
            !S_ISREG(s.st_mode) || s.st_nlink!=1) { e=EINVAL; break; }
        manifest=1;
      } else if (!strcmp(ent->d_name,"segments")) {
        struct stat s;
        if (fstatat(target_fd,"segments",&s,AT_SYMLINK_NOFOLLOW)<0 || !S_ISDIR(s.st_mode)) { e=EINVAL; break; }
        segments_present=1;
      } else { e=EINVAL; break; }
      errno=0;
    }
    if (!e && errno) e=errno;
    if (closedir(dir)<0 && !e) e=errno;
    /* A previous attempt may already have unlinked the manifest after all
     * segments, then lost the directory-fsync/rmdir reply. Resume that exact
     * empty predecessor, but never accept segments without its manifest. */
    if (!manifest && segments_present && !e) e=EINVAL;
    if (e) { close(target_fd); return e; }
    e=reclaim_segments(target_fd,&bytes);
    if (!e && manifest) {
      struct stat s;
      if (fstatat(target_fd,"MANIFEST",&s,AT_SYMLINK_NOFOLLOW)<0) e=errno;
      else if (reclamation_unlink(target_fd,"MANIFEST",0,FAULT_MANIFEST_UNLINK)<0 ||
               promotion_sync(target_fd,FAULT_MANIFEST_UNLINK_SYNC)<0) e=errno;
      else bytes+=(uint64_t)s.st_size;
    }
    if (close(target_fd)<0 && !e) e=errno;
    if (e) return e;
    if (reclamation_unlink(store.epochs_fd,target,AT_REMOVEDIR,FAULT_EPOCH_RMDIR)<0 ||
        promotion_sync(store.epochs_fd,FAULT_EPOCH_RMDIR_SYNC)<0) return errno;
  } else if (promotion_sync(store.epochs_fd,FAULT_EPOCH_RMDIR_SYNC)<0) return errno;
  put(bytes,8); return 0;
}

/* The cold target opens only caller-supplied, already-existing parent
 * directories. It cannot create a STORE until source ownership, inventory and
 * optional catalog verification have all succeeded in Elixir. */
static int cold_target_open(void) {
  if (cold.target || store.acquired || !need(2+32)) return EPROTO;
  store.strict_mode=(int)number(1); store.validated_fs=(int)number(1);
  if (store.strict_mode>1 || store.validated_fs>1) return EINVAL;
#ifndef __linux__
  if (store.strict_mode) return ENOTSUP;
#endif
  if (store.strict_mode && !store.validated_fs) return ENOTSUP;
  cold.source_root.st_dev=(dev_t)number(8); cold.source_root.st_ino=(ino_t)number(8);
  cold.source_segments.st_dev=(dev_t)number(8); cold.source_segments.st_ino=(ino_t)number(8);
  int e=string(cold.parent_path,sizeof(cold.parent_path)); if (e) return e;
  e=string(cold.target_name,sizeof(cold.target_name)); if (e || !basename_ok(cold.target_name)) return e?e:EINVAL;
  e=string(cold.catalog_parent_path,sizeof(cold.catalog_parent_path)); if (e) return e;
  e=string(cold.catalog_name,sizeof(cold.catalog_name)); if (e || !basename_ok(cold.catalog_name)) return e?e:EINVAL;
  if (!need(1)) return EPROTO;
  cold.has_verify=(int)number(1);
  if (cold.has_verify>1) return EINVAL;
  if (cold.has_verify) {
    e=string(cold.verify_parent_path,sizeof(cold.verify_parent_path)); if (e) return e;
    e=string(cold.verify_name,sizeof(cold.verify_name)); if (e || !basename_ok(cold.verify_name)) return e?e:EINVAL;
  }
  if (strcmp(cold.parent_path,cold.catalog_parent_path)==0 && !strcmp(cold.target_name,cold.catalog_name)) return EINVAL;
  e=cold_open_chain(cold.parent_path,&cold.parent_chain); if (e) return e;
  cold.parent_fd=cold.parent_chain.fds[cold.parent_chain.count-1];
  e=cold_open_chain(cold.catalog_parent_path,&cold.catalog_chain); if (e) goto fail;
  cold.catalog_parent_fd=cold.catalog_chain.fds[cold.catalog_chain.count-1];
  if (cold.has_verify) {
    e=cold_open_chain(cold.verify_parent_path,&cold.verify_chain); if (e) goto fail;
    cold.verify_parent_fd=cold.verify_chain.fds[cold.verify_chain.count-1];
  }
  e=cold_chain_aliases_source(&cold.parent_chain); if (e) goto fail;
  e=cold_chain_aliases_source(&cold.catalog_chain); if (e) goto fail;
  if (cold.has_verify) { e=cold_chain_aliases_source(&cold.verify_chain); if (e) goto fail; }
  e=absent_at(cold.parent_fd,cold.target_name); if (e) goto fail;
  e=absent_at(cold.catalog_parent_fd,cold.catalog_name); if (e) goto fail;
  if (store.strict_mode) {
    e=filesystem(cold.parent_fd); if (e) goto fail;
    e=filesystem(cold.catalog_parent_fd); if (e) goto fail;
  }
  cold.target=1; put(store.filesystem_type,8); return 0;

fail:
  abandon_cold_target();
  return e;
}
static int cold_stage_create(void) {
  if (!cold.target || cold.stage_created || !need(2)) return EPROTO;
  int e=string(cold.staging_name,sizeof(cold.staging_name));
  if (e || !basename_ok(cold.staging_name)) return e?e:EINVAL;
  e=string(cold.epoch_name,sizeof(cold.epoch_name));
  if (e || !epoch_name_ok(cold.epoch_name)) return e?e:EINVAL;
  e=cold_check_paths(); if (e) return e;
  e=absent_at(cold.parent_fd,cold.target_name); if (e) return e;
  e=absent_at(cold.catalog_parent_fd,cold.catalog_name); if (e) return e;
  if (mkdirat(cold.parent_fd,cold.staging_name,0700)<0) return errno;
  int stage=openat(cold.parent_fd,cold.staging_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (stage<0) return errno;
  int epochs=-1, epoch=-1, segments=-1;
  if (fstat(stage,&cold.stage_identity)<0) e=errno;
  else if (!S_ISDIR(cold.stage_identity.st_mode)) e=ESTALE;
  if (!e && mkdirat(stage,"epochs",0700)<0) e=errno;
  if (!e) {
    epochs=openat(stage,"epochs",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (epochs<0) e=errno;
  }
  if (!e && mkdirat(epochs,cold.epoch_name,0700)<0) e=errno;
  if (!e) {
    epoch=openat(epochs,cold.epoch_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (epoch<0) e=errno;
  }
  if (!e && mkdirat(epoch,"segments",0700)<0) e=errno;
  if (!e) {
    segments=openat(epoch,"segments",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (segments<0) e=errno;
  }
  if (!e && fstat(epochs,&cold.stage_epochs_identity)<0) e=errno;
  else if (!e && !S_ISDIR(cold.stage_epochs_identity.st_mode)) e=ESTALE;
  if (!e && fstat(epoch,&cold.stage_epoch_identity)<0) e=errno;
  else if (!e && !S_ISDIR(cold.stage_epoch_identity.st_mode)) e=ESTALE;
  if (!e && fstat(segments,&cold.stage_segments_identity)<0) e=errno;
  else if (!e && !S_ISDIR(cold.stage_segments_identity.st_mode)) e=ESTALE;
  if (e) {
    if (segments>=0) close(segments);
    if (epoch>=0) close(epoch);
    if (epochs>=0) close(epochs);
    close(stage);
    return e;
  }
  cold.stage_fd=stage;
  cold.stage_epochs_fd=epochs;
  cold.stage_epoch_fd=epoch;
  cold.stage_segments_fd=segments;
  cold.stage_created=1;
  e=cold_check_paths();
  if (e) {
    close_owned_fd(&cold.stage_segments_fd);
    close_owned_fd(&cold.stage_epoch_fd);
    close_owned_fd(&cold.stage_epochs_fd);
    close_owned_fd(&cold.stage_fd);
    cold.stage_created=0;
  }
  return e;
}
static int cold_scope_fd(int scope) {
  if (scope==SCOPE_ROOT) return cold.stage_fd;
  if (scope==SCOPE_SEGMENTS) return cold.stage_segments_fd;
  if (scope==SCOPE_EPOCH) return cold.stage_epoch_fd;
  if (scope==COLD_SCOPE_CATALOG) return cold.catalog_parent_fd;
  if (scope==COLD_SCOPE_VERIFY) return cold.verify_parent_fd;
  return -1;
}
static int cold_open_write(void) {
  if (!cold.target || store.write_fd>=0 || !need(2)) return EPROTO;
  int scope=(int)number(1), lock=(int)number(1), fd=cold_scope_fd(scope);
  int e=string(store.write_name,sizeof(store.write_name));
  if (e || !basename_ok(store.write_name) || fd<0 || lock>1 || scope==COLD_SCOPE_VERIFY)
    return e?e:EINVAL;
  if (scope==COLD_SCOPE_CATALOG && strcmp(store.write_name,cold.catalog_name)) return EINVAL;
  if (scope!=COLD_SCOPE_CATALOG && scope!=COLD_SCOPE_VERIFY && !cold.stage_created) return EBADF;
  e=cold_check_paths(); if (e) return e;
  store.write_scope=scope; store.write_kind=WRITE_COLD_COPY;
  store.write_fd=openat(fd,store.write_name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if (store.write_fd<0) return errno;
  e=checked_regular(store.write_fd,fd,store.write_name,&store.write_identity);
  if (e) { close(store.write_fd); store.write_fd=-1; return e; }
  if (lock) {
    if (cold.lock_fd>=0 || flock(store.write_fd,LOCK_EX|LOCK_NB)<0) { e=cold.lock_fd>=0?EBUSY:errno; close(store.write_fd); store.write_fd=-1; return e; }
    cold.lock_fd=dup(store.write_fd);
    if (cold.lock_fd<0) { e=errno; close(store.write_fd); store.write_fd=-1; return e; }
    if (fstat(cold.lock_fd,&cold.lock_identity)<0) { e=errno; close(cold.lock_fd); cold.lock_fd=-1; close(store.write_fd); store.write_fd=-1; return e; }
  }
  stat_out(&store.write_identity); return 0;
}
static int cold_sync_staging(void) {
  int e=cold_check_paths(); if (e) return e;
  if (!cold.stage_created || fsync(cold.stage_segments_fd)<0 ||
      fsync(cold.stage_epoch_fd)<0 || fsync(cold.stage_epochs_fd)<0) return errno;
  return fsync(cold.stage_fd)<0?errno:0;
}
static int cold_publish(void) {
  int e=cold_check_paths(); if (e) return e;
  if (!cold.stage_created || store.write_fd>=0) return EBUSY;
  e=absent_at(cold.parent_fd,cold.target_name); if (e) return e;
  if (no_replace(cold.parent_fd,cold.staging_name,cold.target_name)<0) return errno;
  cold.published=1;
  if (store.strict_mode)
    for (size_t i=cold.parent_chain.count;i>0;i--) if (fsync(cold.parent_chain.fds[i-1])<0) return errno;
  return 0;
}
static int cold_sync_catalog(void) {
  int e=cold_check_paths(); if (e) return e;
  if (store.write_fd>=0) return EBUSY;
  if (store.strict_mode)
    for (size_t i=cold.catalog_chain.count;i>0;i--) if (fsync(cold.catalog_chain.fds[i-1])<0) return errno;
  return 0;
}
static int cold_list_directory(void) {
  if (!need(5)) return EPROTO;
  int scope=(int)number(1), fd=scope_fd(scope);
  uint32_t limit=(uint32_t)number(4);
  if (!cold.source || !limit || fd<0 ||
      !(scope==SCOPE_ROOT || scope==SCOPE_SEGMENTS || scope==SCOPE_EPOCH)) return EINVAL;
  /* Reuse the normal listing implementation's wire format, but give the
   * caller its remaining global budget so copy inventory stops incrementally. */
  uint32_t saved=store.directory_limit; store.directory_limit=limit;
  unsigned char body[1]={ (unsigned char)scope };
  const unsigned char *saved_input=input; size_t saved_n=input_n,saved_pos=pos;
  input=body; input_n=1; pos=0;
  int e=list_directory();
  input=saved_input; input_n=saved_n; pos=saved_pos; store.directory_limit=saved;
  return e;
}
static int list_directory(void) {
  if (!need(1)) return EPROTO;
  int scope=(int)number(1), fd=scope_fd(scope);
  if (fd<0) return scope==SCOPE_SEGMENTS?ENOENT:EINVAL;
  /* A new open file description avoids shared directory offsets with dup(). */
  int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if (copy<0) return errno;
  DIR *dir=fdopendir(copy); if (!dir) { int e=errno; close(copy); return e; }
  put(0,4); uint32_t count=0; struct dirent *ent; int e=0;
  errno=0;
  while ((ent=readdir(dir))) {
    if (!strcmp(ent->d_name,".") || !strcmp(ent->d_name,"..")) continue;
    if (count>=store.directory_limit) { e=EFBIG; break; }
    size_t n=strlen(ent->d_name); struct stat s;
    if (output_n+n+55>PACKET_MAX-23) { e=EFBIG; break; }
    if (fstatat(fd,ent->d_name,&s,AT_SYMLINK_NOFOLLOW)<0) { e=errno; break; }
    put(n,2); memcpy(output+output_n,ent->d_name,n); output_n+=n; stat_out(&s); count++;
    errno=0;
  }
  if (!e && errno) e=errno;
  if (closedir(dir)<0 && !e) e=errno;
  for (int i=0;i<4;i++) output[i]=(unsigned char)(count>>((3-i)*8));
  return e;
}
static int open_read(void) {
  if (store.read_fd>=0 || !need(1)) return EBUSY;
  store.read_scope=(int)number(1); int fd=scope_fd(store.read_scope);
  int e=string(store.read_name,sizeof(store.read_name));
  if (e || !basename_ok(store.read_name) || fd<0 ||
      (store.read_scope==SCOPE_COLD_VERIFY && strcmp(store.read_name,cold.verify_name))) return e?e:EINVAL;
  store.read_fd=openat(fd,store.read_name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  if (store.read_fd<0) return errno;
  e=checked_regular(store.read_fd,fd,store.read_name,&store.read_identity);
  if (e) { close(store.read_fd); store.read_fd=-1; return e; }
  stat_out(&store.read_identity); return 0;
}
static int validate_read(void) {
  struct stat now;
  if (store.read_fd<0) return EBADF;
  int e=checked_regular(store.read_fd,scope_fd(store.read_scope),store.read_name,&now);
  if (e) return e;
  return same(&now,&store.read_identity) && now.st_size==store.read_identity.st_size ? 0 : ESTALE;
}
static int read_at(void) {
  if (!need(12)) return EPROTO;
  uint64_t off=number(8), n=number(4);
  if (n>IO_BODY_MAX || n>sizeof(output) || off>INT64_MAX ||
      n>(uint64_t)INT64_MAX-off ||
      (!cold.source && (off>SEGMENT_MAX_BYTES || off+n>SEGMENT_MAX_BYTES))) return EFBIG;
  int e=validate_read(); if (e) return e;
#ifdef TAY_TEST_FAULTS
  if (fault_now && fault_action==FAULT_SHORT_IO && n) n=fault_short<n?fault_short:n-1;
#endif
  ssize_t got=pread(store.read_fd,output,(size_t)n,(off_t)off);
  if (got<0) return errno;
  output_n=(size_t)got; return validate_read();
}
static int create_stage(void) {
  if (!need(1)) return EPROTO;
  int scope=(int)number(1);
  int candidate=scope==SCOPE_CANDIDATE || scope==SCOPE_CANDIDATE_SEGMENTS;
  int *target=candidate?&pending_epoch.write_fd:&store.write_fd;
  int *target_scope=candidate?&pending_epoch.write_scope:&store.write_scope;
  int *target_kind=candidate?&pending_epoch.write_kind:&store.write_kind;
  char *target_name=candidate?pending_epoch.write_name:store.write_name;
  struct stat *target_identity=candidate?&pending_epoch.write_identity:&store.write_identity;
  if (*target>=0) return EBUSY;
  int fd=scope_fd(scope), kind;
  char name[256];
  struct stat identity;
  int e=string(name,sizeof(name));
  if (e) return e;
  kind=stage_kind(scope,name);
  if (!kind || fd<0) return EINVAL;
  int opened=openat(fd,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if (opened<0) return errno;
  e=checked_regular(opened,fd,name,&identity);
  if (e) { close(opened); return e; }
  *target=opened;
  *target_scope=scope;
  *target_kind=kind;
  strcpy(target_name,name);
  *target_identity=identity;
  stat_out(target_identity);
  return 0;
}
static int open_active(void) {
  if (store.write_fd>=0) return EBUSY;
  int e=string(store.write_name,sizeof(store.write_name));
  if (e || !need(24) || !canonical(store.write_name)) return e?e:EINVAL;
  uint64_t size=number(8), dev=number(8), ino=number(8);
  store.write_scope=SCOPE_SEGMENTS; store.write_kind=WRITE_SEGMENT;
  store.write_fd=openat(store.segments_fd,store.write_name,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  if (store.write_fd<0) return errno;
  e=checked_regular(store.write_fd,store.segments_fd,store.write_name,&store.write_identity);
  if (!e && ((uint64_t)store.write_identity.st_size!=size || (uint64_t)store.write_identity.st_dev!=dev ||
     (uint64_t)store.write_identity.st_ino!=ino)) e=ESTALE;
  if (!e && (size<SEGMENT_HEADER_BYTES ||
      size>SEGMENT_MAX_BYTES-SEGMENT_FOOTER_BYTES)) e=EINVAL;
  if (e) { close(store.write_fd); store.write_fd=-1; return e; }
  stat_out(&store.write_identity); return 0;
}

static int verify_written_bytes(int fd,uint64_t off,const unsigned char *expected,size_t n) {
  size_t capacity=n<READBACK_VERIFY_CHUNK_BYTES?n:READBACK_VERIFY_CHUNK_BYTES;
  unsigned char *readback=malloc(capacity);
  if (!readback) return ENOMEM;
  int e=0;
  size_t checked=0;
  while (!e && checked<n) {
    size_t chunk=n-checked<capacity?n-checked:capacity;
    ssize_t got=pread(fd,readback,chunk,(off_t)(off+checked));
    if (got<0) e=errno;
    else if ((size_t)got!=chunk || memcmp(readback,expected+checked,chunk)) e=EIO;
    checked+=chunk;
  }
  free(readback);
  return e;
}

static int write_at(void) {
  if (!need(WRITE_REQUEST_PREFIX_BYTES)) return EPROTO;
  int candidate=(int)number(1);
  int fd=candidate?pending_epoch.write_fd:store.write_fd;
  int kind=candidate?pending_epoch.write_kind:store.write_kind;
  if (candidate<0 || candidate>1 || fd<0) return EBADF;
  uint64_t off=number(8); size_t n=input_n-pos;
  size_t fixed_size=staged_write_size(kind);
  struct stat s;
  if (fstat(fd,&s)<0) return errno;
  if (!n || n>IO_BODY_MAX || off!=(uint64_t)s.st_size || off>INT64_MAX ||
      n>(uint64_t)INT64_MAX-off ||
      (kind!=WRITE_COLD_COPY &&
       (off>SEGMENT_MAX_BYTES || n>SEGMENT_MAX_BYTES-off))) return EINVAL;
  if (fixed_size && (off!=0 || n!=fixed_size)) return EINVAL;
  size_t requested=n;
#ifdef TAY_TEST_FAULTS
  if (fault_now && fault_action==FAULT_SHORT_IO) n=(size_t)(fault_short<n?fault_short:n-1);
#endif
  /* A single filesystem pwrite. No EINTR/short-write retry is legal here. */
  store.known_written=UINT64_MAX; /* A failed syscall need not prove zero changed bytes. */
  ssize_t result;
#ifdef TAY_TEST_FAULTS
  if (fault_now && fault_action==FAULT_SYSCALL_ERROR_AFTER_CALL) {
    errno=fault_errno?fault_errno:EIO; result=-1;
  }
  else
#endif
  result=pwrite(fd,input+pos,n,(off_t)off);
  if (result<0) return errno;
  store.known_written=(uint64_t)result;
  if ((size_t)result!=requested) {
#ifdef TAY_TEST_FAULTS
    if (fault_now && fault_action==FAULT_SHORT_IO) return fault_errno?fault_errno:EIO;
#endif
    return EIO;
  }
  if (fstat(fd,&s)<0) return errno;
  if ((uint64_t)s.st_size!=off+requested) return ESTALE;
  int e=verify_written_bytes(fd,off,input+pos,requested);
  pos=input_n;
  if (!e) {
    if (candidate) pending_epoch.write_identity=s; else store.write_identity=s;
    stat_out(&s);
  }
  return e;
}
static int publish(void) {
  if (store.write_fd>=0 || !need(1)) return EBUSY;
  int scope=(int)number(1), fd=scope_fd(scope);
  char source[256], target[256];
  int e=string(source,sizeof(source)); if (e) return e;
  e=string(target,sizeof(target)); if (e || !need(16)) return e?e:EPROTO;
  uint64_t dev=number(8), ino=number(8);
  int kind=stage_kind(scope,source);
  size_t expected_size=staged_write_size(kind);
  if (fd<0 || !kind || (scope!=SCOPE_ROOT && scope!=SCOPE_SEGMENTS) ||
      (scope==SCOPE_ROOT && !(kind==WRITE_STORE_V2_STAGE && !strcmp(target,"STORE-V2"))) ||
      (scope==SCOPE_SEGMENTS &&
       (!canonical(target) ||
        strncmp(source+STRING_BYTES(SEGMENT_STAGE_PREFIX),target,SEGMENT_ID_DIGITS))))
    return EINVAL;
  struct stat s, after;
  if (fstatat(fd,source,&s,AT_SYMLINK_NOFOLLOW)<0) return errno;
  if (!S_ISREG(s.st_mode) || s.st_nlink!=1 || (uint64_t)s.st_dev!=dev || (uint64_t)s.st_ino!=ino ||
      expected_size==0 || (uint64_t)s.st_size!=expected_size) return ESTALE;
  if (no_replace(fd,source,target)<0) return errno;
  if (fstatat(fd,target,&after,AT_SYMLINK_NOFOLLOW)<0) return errno;
  return same(&s,&after) && after.st_nlink==1 ? 0 : ESTALE;
}

static int inspection_opcode_allowed(unsigned op) {
  switch (op) {
    case LIST: case OPEN_READ: case READ_AT: case CLOSE_READ: case CHECK: case INFO:
    case V2_SELECT: case V2_SPACE:
      return 1;
    default:
      return 0;
  }
}

static int cold_target_opcode_allowed(unsigned op) {
  switch (op) {
    case COLD_STAGE_CREATE: case COLD_OPEN_WRITE: case COLD_SYNC_STAGING:
    case COLD_PUBLISH: case COLD_SYNC_CATALOG: case COLD_CHECK:
    case OPEN_READ: case READ_AT: case CLOSE_READ: case SYNC_READ:
    case WRITE_AT: case SYNC_FILE: case CLOSE_WRITE:
      return 1;
    default:
      return 0;
  }
}

static int failure_poisons(unsigned op) {
  switch (op) {
    case LIST: case OPEN_READ: case READ_AT: case CLOSE_READ: case V2_RECLAIM:
      return 0;
    default:
      return 1;
  }
}

static int dispatch(unsigned op) {
  int e=0, fd;
  if (op==ACQUIRE || op==ACQUIRE_EXISTING || op==ACQUIRE_IF_MISSING) {
    if (store.poisoned || store.root_fd>=0) return ECANCELED;
    return acquire(op==ACQUIRE_EXISTING?1:op==ACQUIRE_IF_MISSING?2:0);
  }
  if (op==COLD_TARGET_OPEN) {
    if (store.poisoned) return ECANCELED;
    return cold_target_open();
  }
  if (op==SHUTDOWN) {
    shutdown_owned_handles();
    return 0;
  }
#ifdef TAY_TEST_FAULTS
  if (op==FAULT) {
    if (!need(19)) return EPROTO;
    fault_op=(int)number(2); fault_n=(int)number(4); fault_action=(int)number(1);
    fault_errno=(int)number(4); fault_short=number(8); return 0;
  }
#endif
  if (store.poisoned) return ECANCELED;
  if (cold.target) {
    e=cold_check_paths(); if (e) return e;
    if (!cold_target_opcode_allowed(op)) return EPROTO;
    switch (op) {
      case COLD_STAGE_CREATE: return cold_stage_create();
      case COLD_OPEN_WRITE: return cold_open_write();
      case COLD_SYNC_STAGING: return cold_sync_staging();
      case COLD_PUBLISH: return cold_publish();
      case COLD_SYNC_CATALOG: return cold_sync_catalog();
      case COLD_CHECK: return cold_check_paths();
      case OPEN_READ: case READ_AT: case CLOSE_READ: case SYNC_READ:
        break;
      case WRITE_AT: case SYNC_FILE: case CLOSE_WRITE:
        break;
      default: return EPROTO;
    }
  }
  if (op==COLD_SOURCE) {
    e=check_paths(); if (e) return e;
    if (!store.inspection_only) return EPERM;
    cold.source=1; return 0;
  }
  if (op==COLD_LIST) {
    e=check_paths(); if (e) return e;
    if (!store.inspection_only) return EPERM;
    return cold_list_directory();
  }
  if (!cold.target) {
    e=check_paths(); if (e) return e;
  }
  if (op==ENABLE_MUTATIONS) return enable_mutations();
  if (!cold.target && store.inspection_only && !inspection_opcode_allowed(op)) return EPERM;
  switch (op) {
    case V2_SELECT: return v2_select();
    case V2_BEGIN: return v2_begin();
    case V2_PUBLISH_EPOCH: return v2_publish_epoch();
    case V2_PUBLISH_CURRENT: return v2_publish_current();
    case V2_SPACE: return v2_space();
    case V2_RECLAIM: return v2_reclaim();
    case V2_ABORT: return v2_abort();
    case LIST: return list_directory();
    case MKDIR_SEGMENTS:
      if (store.segments_fd>=0) return EEXIST;
      if (mkdirat(store.root_fd,"segments",0700)<0) return errno;
      return open_segments();
    case OPEN_READ: return open_read();
    case READ_AT: return read_at();
    case CLOSE_READ:
      e=validate_read(); fd=store.read_fd; store.read_fd=-1;
      if (fd>=0 && close(fd)<0 && !e) e=errno;
      return e;
    case CREATE_STAGE: return create_stage();
    case OPEN_ACTIVE: return open_active();
    case WRITE_AT: return write_at();
    case SYNC_FILE:
      if (!need(1)) return EPROTO;
      fd=number(1)?pending_epoch.write_fd:store.write_fd;
      return fd<0?EBADF:fsync(fd)<0?errno:0;
    case CLOSE_WRITE: {
      if (!need(1)) return EPROTO;
      int candidate=(int)number(1);
      fd=candidate?pending_epoch.write_fd:store.write_fd;
      if (candidate) { pending_epoch.write_fd=-1; pending_epoch.write_kind=WRITE_NONE; }
      else { store.write_fd=-1; store.write_kind=WRITE_NONE; }
      return fd<0?EBADF:close(fd)<0?errno:0;
    }
    case PUBLISH: return publish();
    case SYNC_DIR:
      if (!need(1)) return EPROTO;
      fd=scope_fd((int)number(1)); return fd<0?ENOENT:fsync(fd)<0?errno:0;
    case CHECK: return check_paths();
    case INFO:
      put((uint64_t)getpid(),8); put(store.write_fd<0?WRITE_NONE:store.write_kind,1); put(store.read_fd>=0,1);
      put(store.filesystem_type,8); put(store.ancestor_syncs,4);
      if (store.acquired) {
        struct stat root,segments;
        if (fstat(store.root_fd,&root)<0) return errno;
        put((uint64_t)root.st_dev,8); put((uint64_t)root.st_ino,8);
        if (store.segments_fd>=0) {
          if (fstat(store.segments_fd,&segments)<0) return errno;
          put((uint64_t)segments.st_dev,8); put((uint64_t)segments.st_ino,8);
        } else {
          put(0,8); put(0,8);
        }
      }
      return 0;
    case SYNC_READ:
      e=validate_read(); return e?e:fsync(store.read_fd)<0?errno:0;
    default: return EPROTO;
  }
}
/* Reject malformed control messages before any filesystem operation. */
static int validate_request(unsigned op) {
  char name[PATH_MAX]; int e=0;
  switch (op) {
    case ACQUIRE: case ACQUIRE_EXISTING: case ACQUIRE_IF_MISSING:
      if (!need(op==ACQUIRE_EXISTING?6:2)) return EPROTO;
      pos+=op==ACQUIRE_EXISTING?6:2; e=string(name,sizeof(name)); break;
    case LIST: case SYNC_DIR:
      if (!need(1)) return EPROTO;
      pos++; break;
    case OPEN_READ: case CREATE_STAGE:
      if (!need(1)) return EPROTO;
      pos++; e=string(name,256); break;
    case V2_SELECT: case V2_BEGIN: case V2_PUBLISH_EPOCH:
      e=string(name,256); break;
    case V2_PUBLISH_CURRENT:
      e=string(name,256);
      if (e || !need(FILE_IDENTITY_PAIR_BYTES)) return e?e:EPROTO;
      pos+=FILE_IDENTITY_PAIR_BYTES; break;
    case V2_RECLAIM:
      e=string(name,256); if (e || !need(RECLAIM_BASE_BYTES)) return e?e:EPROTO;
      pos+=CURRENT_METADATA_BYTES;
      if (number(1)) {
        if (!need(AUTHORITY_METADATA_BYTES)) return EPROTO;
        pos+=AUTHORITY_METADATA_BYTES;
      }
      break;
    case COLD_STAGE_CREATE:
      e=string(name,256); if (!e) e=string(name,256); break;
    case COLD_OPEN_WRITE:
      if (!need(2)) return EPROTO;
      pos+=2; e=string(name,256); break;
    case COLD_TARGET_OPEN: {
      if (!need(34)) return EPROTO;
      pos+=34;
      for (int i=0;i<4 && !e;i++) e=string(name,i==0 || i==2?PATH_MAX:256);
      if (e || !need(1)) return e?e:EPROTO;
      unsigned verify=(unsigned)number(1);
      if (verify>1) return EPROTO;
      if (verify) {
        e=string(name,PATH_MAX);
        if (!e) e=string(name,256);
      }
      break;
    }
    case COLD_LIST:
      if (!need(5)) return EPROTO;
      pos+=5; break;
    case READ_AT:
      if (!need(12)) return EPROTO;
      pos+=12; break;
    case OPEN_ACTIVE:
      e=string(name,256); if (e) return e;
      if (!need(24)) return EPROTO;
      pos+=24; break;
    case WRITE_AT:
      if (!need(WRITE_REQUEST_PREFIX_BYTES) ||
          input_n-pos>IO_BODY_MAX+WRITE_REQUEST_PREFIX_BYTES) return EPROTO;
      pos=input_n; break;
    case PUBLISH:
      if (!need(1)) return EPROTO;
      pos++; e=string(name,256); if (e) return e;
      e=string(name,256); if (e) return e;
      if (!need(16)) return EPROTO;
      pos+=16; break;
    case SYNC_FILE: case CLOSE_WRITE:
      if (!need(1)) return EPROTO;
      pos++; break;
    case MKDIR_SEGMENTS: case CLOSE_READ:
    case CHECK: case INFO: case SYNC_READ: case SHUTDOWN: case ENABLE_MUTATIONS: case V2_SPACE:
    case V2_ABORT:
    case COLD_SYNC_STAGING: case COLD_PUBLISH: case COLD_SYNC_CATALOG:
    case COLD_CHECK: case COLD_SOURCE: break;
#ifdef TAY_TEST_FAULTS
    case FAULT:
      if (!need(19)) return EPROTO;
      pos+=19; break;
#endif
    default:return EPROTO;
  }
  return e?e:pos==input_n?0:EPROTO;
}
static const char *error_name(int e) {
  switch (e) {
    case ENOENT:return "enoent"; case EEXIST:return "eexist";
    case EACCES:return "eacces"; case EPERM:return "eperm";
    case ENOSPC:return "enospc"; case EIO:return "eio";
    case EBADF:return "ebadf"; case EINTR:return "eintr";
    case EWOULDBLOCK:return "store_busy"; case EBUSY:return "ebusy";
    case EINVAL:return "einval"; case ELOOP:return "eloop";
    case ENOTDIR:return "enotdir"; case EMLINK:return "hard_link";
    case ESTALE:return "path_or_extent_changed"; case EFBIG:return "resource_limit";
    case ECANCELED:return "poisoned"; case ENOTSUP:return "unsupported_capability";
    case ENOSYS:return "unsupported_syscall"; case EPROTO:return "invalid_protocol";
    default:return "native_error";
  }
}
/* Channel I/O may retry transport interruptions; filesystem writes never do. */
static int transfer(int fd,void *bytes,size_t n,int writing) {
  unsigned char *p=bytes;
  while (n) {
    ssize_t k=writing?write(fd,p,n):read(fd,p,n);
    if (k<0 && errno==EINTR) continue;
    if (k<=0) return -1;
    p+=k; n-=(size_t)k;
  }
  return 0;
}
int main(void) {
  signal(SIGPIPE,SIG_IGN);
  unsigned char *packet=NULL;
  size_t packet_capacity=0;
  for (;;) {
    unsigned char size_bytes[PACKET_LENGTH_BYTES];
    if (transfer(STDIN_FILENO,size_bytes,PACKET_LENGTH_BYTES,0)<0) break;
    uint32_t size=0;
    for (size_t i=0;i<PACKET_LENGTH_BYTES;i++) size=(size<<8)|size_bytes[i];
    if (size<REQUEST_HEADER_BYTES || size>PACKET_MAX) break;
    if (size>packet_capacity) {
      size_t next=packet_capacity?packet_capacity:INITIAL_PACKET_CAPACITY_BYTES;
      while (next<size && next<PACKET_MAX/PACKET_CAPACITY_GROWTH_FACTOR)
        next*=PACKET_CAPACITY_GROWTH_FACTOR;
      if (next<size) next=PACKET_MAX;
      unsigned char *grown=realloc(packet,next); if (!grown) break;
      packet=grown; packet_capacity=next;
    }
    if (transfer(STDIN_FILENO,packet,size,0)<0) break;
    input=packet; input_n=size; pos=0;
    unsigned version=(unsigned)number(PROTOCOL_VERSION_BYTES);
    unsigned op=(unsigned)number(OPERATION_CODE_BYTES);
    uint64_t id=number(REQUEST_ID_BYTES);
    output_n=0; store.known_written=0;
    int e=0;
#ifdef TAY_TEST_FAULTS
    fault_now=(op==(unsigned)fault_op && fault_n>0 && --fault_n==0);
    if (fault_now && fault_action==FAULT_ERROR_BEFORE_CALL) e=fault_errno?fault_errno:EIO;
    else if (fault_now && fault_action==FAULT_HELPER_CRASH_BEFORE_CALL)
      _exit(HELPER_EXIT_CRASH_BEFORE_CALL);
    else if (fault_now && fault_action==FAULT_OWNER_VM_CRASH_BEFORE_CALL) kill_owner_vm();
    else if (fault_now && fault_action==FAULT_LOSE_LOCK) {
      if (store.lock_fd>=0) {
        close(store.lock_fd);
      }
      store.lock_fd=-1;
    }
#endif
    if (!e) e=version==PROTOCOL_VERSION?validate_request(op):EPROTO;
    if (!e) { pos=REQUEST_HEADER_BYTES; e=dispatch(op); }
    if (!e && pos!=input_n) e=EPROTO;
    if (!e && store.acquired) e=check_paths();
    if (e && failure_poisons(op)) store.poisoned=1;
#ifdef TAY_TEST_FAULTS
    if (fault_now && fault_action==FAULT_HELPER_CRASH_AFTER_CALL)
      _exit(HELPER_EXIT_CRASH_AFTER_CALL);
    if (fault_now && fault_action==FAULT_OWNER_VM_CRASH_AFTER_CALL) kill_owner_vm();
    if (fault_now && fault_action==FAULT_DROP_REPLY) continue;
    if (fault_now && fault_action==FAULT_INVALID_REPLY_ID) id^=1;
#endif
    if (e) {
      const char *reason=error_name(e); output_n=strlen(reason); memcpy(output,reason,output_n);
    }
    size_t body_n=output_n;
    unsigned char reply[FRAMED_REPLY_HEADER_BYTES];
    uint32_t total=(uint32_t)body_n+REPLY_HEADER_BYTES;
    encode_big_endian(reply,total,PACKET_LENGTH_BYTES);
    reply[REPLY_VERSION_OFFSET]=PROTOCOL_VERSION;
    reply[REPLY_OPERATION_OFFSET]=(unsigned char)op;
    encode_big_endian(reply+REPLY_REQUEST_ID_OFFSET,id,REQUEST_ID_BYTES);
    reply[REPLY_ERROR_FLAG_OFFSET]=e?1:0;
    encode_big_endian(reply+REPLY_ERROR_CODE_OFFSET,(uint32_t)e,ERROR_CODE_BYTES);
    encode_big_endian(reply+REPLY_KNOWN_WRITTEN_OFFSET,store.known_written,KNOWN_WRITTEN_BYTES);
    int sent=transfer(STDOUT_FILENO,reply,FRAMED_REPLY_HEADER_BYTES,1);
    if (sent==0 && body_n) sent=transfer(STDOUT_FILENO,output,body_n,1);
    if (sent<0 || op==SHUTDOWN) break;
  }
  free(packet);
  /* Process exit closes every pinned descriptor and releases flock together. */
  return 0;
}
