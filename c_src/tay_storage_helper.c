/* Tay filesystem Port, protocol v1. No checksums, events, or repair code. */
#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
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

#define PACKET_MAX (16777244u + 8192u)
#define SEGMENT_MAX 1073741824ull
enum { ACQUIRE=1, LIST=2, MKDIR_SEGMENTS=3, OPEN_READ=4, READ_AT=5,
  CLOSE_READ=6, CREATE_STAGE=7, OPEN_ACTIVE=8, WRITE_AT=9, SYNC_FILE=10,
  CLOSE_WRITE=11, PUBLISH=12, SYNC_DIR=13, CHECK=14, INFO=15,
  SYNC_READ=16, SHUTDOWN=17, ACQUIRE_EXISTING=18, ENABLE_MUTATIONS=19, FAULT=240 };
static int root_fd=-1, segments_fd=-1, lock_fd=-1, read_fd=-1, write_fd=-1;
static int write_scope, write_kind, read_scope, poisoned, acquired;
static char root_path[PATH_MAX], write_name[256], read_name[256];
static struct stat read_identity, write_identity;
static int strict_mode, validated_fs, root_created;
static uint64_t filesystem_type, known_written;
static uint32_t ancestor_syncs;
static int inspection_only;
static uint32_t directory_limit=UINT32_MAX;
static const unsigned char *input;
static size_t input_n, pos;
static unsigned char output[PACKET_MAX];
static size_t output_n;

#ifdef TAY_TEST_FAULTS
static int fault_op, fault_n, fault_action, fault_errno;
static uint64_t fault_short;
static int fault_now;
#endif

/* Targets 241..244 exist only as test fault sites, never request opcodes. */
static int promotion_sync(int fd, unsigned target) {
#ifdef TAY_TEST_FAULTS
  int hit=fault_op==(int)target && fault_n>0 && --fault_n==0;
  if (hit) {
    fault_now=1;
    if (fault_action==5) _exit(95);
    if (fault_action==1 || fault_action==8) { errno=fault_errno?fault_errno:EIO; return -1; }
  }
#else
  (void)target;
#endif
  int result=fsync(fd);
#ifdef TAY_TEST_FAULTS
  if (hit && fault_action==3) _exit(93);
#endif
  return result;
}

static int need(size_t n) { return n <= input_n-pos; }
static uint64_t number(size_t n) {
  uint64_t v=0; for (size_t i=0;i<n;i++) v=(v<<8)|input[pos++]; return v;
}
static void put(uint64_t n, size_t width) {
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
static int scope_fd(int scope) { return scope==0 ? root_fd : scope==1 ? segments_fd : -1; }
static int same(const struct stat *a,const struct stat *b) {
  return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static unsigned int type_of(mode_t mode) {
  return S_ISREG(mode)?1:S_ISDIR(mode)?2:S_ISLNK(mode)?3:4;
}
static void stat_out(const struct stat *s) {
  put((uint64_t)s->st_size,8); put((uint64_t)s->st_dev,8); put((uint64_t)s->st_ino,8);
  put((uint64_t)s->st_nlink,8); put(type_of(s->st_mode),1); put((uint32_t)s->st_mode,4);
}
static int checked_regular(int fd, int directory, const char *name, struct stat *s) {
  struct stat path;
  if (fstat(fd,s)<0 || fstatat(directory,name,&path,AT_SYMLINK_NOFOLLOW)<0) return errno;
  if (!S_ISREG(s->st_mode) || !S_ISREG(path.st_mode)) return EINVAL;
  if (s->st_nlink!=1 || path.st_nlink!=1) return EMLINK;
  return same(s,&path)?0:ESTALE;
}
static int no_replace(int fd,const char *src,const char *dst) {
#ifdef __linux__
  return (int)syscall(SYS_renameat2,fd,src,fd,dst,RENAME_NOREPLACE);
#elif defined(__APPLE__)
  return renameatx_np(fd,src,fd,dst,RENAME_EXCL);
#else
  (void)fd; (void)src; (void)dst; errno=ENOTSUP; return -1;
#endif
}
static int rename_capability(void) {
#ifdef __APPLE__
  struct attrlist attrs;
  memset(&attrs,0,sizeof(attrs)); attrs.bitmapcount=ATTR_BIT_MAP_COUNT;
  attrs.volattr=ATTR_VOL_INFO|ATTR_VOL_CAPABILITIES;
  struct { uint32_t size; vol_capabilities_attr_t caps; } result;
  memset(&result,0,sizeof(result));
  if (fgetattrlist(root_fd,&attrs,&result,sizeof(result),0)<0) return errno;
  unsigned i=VOL_CAPABILITIES_INTERFACES;
  return (result.caps.valid[i] & VOL_CAP_INT_RENAME_EXCL) &&
    (result.caps.capabilities[i] & VOL_CAP_INT_RENAME_EXCL) ? 0 : ENOTSUP;
#else
  if (no_replace(root_fd,".tay-owner.lock",".tay-owner.lock")==0) return ENOTSUP;
  return errno==EEXIST?0:errno;
#endif
}
static int filesystem(int fd) {
  struct statfs s;
  if (fstatfs(fd,&s)<0) return errno;
#ifdef __linux__
  uint64_t t=(uint64_t)(unsigned long)s.f_type;
  filesystem_type=t;
  int persistent=(t==0xEF53u || t==0x58465342u || t==0x9123683Eu);
  int development=persistent || t==0x01021994u || t==0x794c7630u;
  if (strict_mode) return validated_fs && persistent ? 0 : ENOTSUP;
  return development ? 0 : ENOTSUP;
#elif defined(__APPLE__)
  filesystem_type=0;
  if (strict_mode) return ENOTSUP;
  return (s.f_flags & MNT_LOCAL) && (!strcmp(s.f_fstypename,"apfs") || !strcmp(s.f_fstypename,"hfs")) ? 0 : ENOTSUP;
#else
  return ENOTSUP;
#endif
}
/* Walk from a pinned / FD. Never follow a symlink or use cwd resolution. */
static int walk_root(int create, int *result, int *created) {
  char path[PATH_MAX]; memcpy(path,root_path,strlen(root_path)+1);
  if (path[0]!='/' || !strcmp(path,"/")) return EINVAL;
  int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  if (fd<0) return errno;
  char *save=NULL, *part=strtok_r(path,"/",&save);
  *created=0;
  while (part) {
    char *next=strtok_r(NULL,"/",&save);
    if (!basename_ok(part)) { close(fd); return EINVAL; }
    int child=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (child<0 && errno==ENOENT && create==1) {
      int e=filesystem(fd);
      if (e) { close(fd); return e; }
      if (mkdirat(fd,part,0700)<0) { e=errno; close(fd); return e; }
      if (!next) *created=1;
      child=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    }
    if (child<0) { int e=errno; close(fd); return e; }
    /* Existing entries can belong to an interrupted earlier mkdir/fsync. */
    if (create) {
      int synced=create==2?promotion_sync(fd,241):fsync(fd);
      if (synced<0) { int e=errno; close(child); close(fd); return e; }
      ancestor_syncs++;
    }
    if (close(fd)<0) { int e=errno; close(child); return e; }
    fd=child; part=next;
  }
  *result=fd; return 0;
}
static int check_paths(void) {
  if (!acquired || root_fd<0 || lock_fd<0) return EBADF;
  int current=-1, created=0;
  int e=walk_root(0,&current,&created);
  if (e) return e;
  struct stat root, path, lock;
  if (fstat(root_fd,&root)<0 || fstat(current,&path)<0) { e=errno; close(current); return e; }
  if (close(current)<0) return errno;
  if (!same(&root,&path)) return ESTALE;
  e=checked_regular(lock_fd,root_fd,".tay-owner.lock",&lock);
  if (e) return e;
  if (segments_fd>=0) {
    if (fstat(segments_fd,&root)<0 || fstatat(root_fd,"segments",&path,AT_SYMLINK_NOFOLLOW)<0) return errno;
    if (!S_ISDIR(path.st_mode) || !same(&root,&path)) return ESTALE;
  }
  if (write_fd>=0) {
    struct stat now;
    e=checked_regular(write_fd,scope_fd(write_scope),write_name,&now);
    if (e) return e;
    if (!same(&now,&write_identity)) return ESTALE;
  }
  return 0;
}
static int open_segments(void) {
  if (segments_fd>=0) return 0;
  segments_fd=openat(root_fd,"segments",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (segments_fd<0) return errno;
  int e=filesystem(segments_fd);
  if (e) { close(segments_fd); segments_fd=-1; }
  return e;
}
static int canonical(const char *name) {
  if (strlen(name)!=24 || strcmp(name+20,".tay")) return 0;
  uint64_t id=0;
  for (int i=0;i<20;i++) {
    if (name[i]<'0'||name[i]>'9') return 0;
    unsigned d=(unsigned)(name[i]-'0');
    if (id>(UINT64_MAX-d)/10) return 0;
    id=id*10+d;
  }
  return id!=0;
}
static int nonce(const char *s) {
  for (int i=0;i<32;i++) if (!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f'))) return 0;
  return !strcmp(s+32,".tmp");
}
static int stage_kind(int scope,const char *name) {
  if (scope==0 && strlen(name)==47 && !strncmp(name,".tay-store-",11) && nonce(name+11)) return 3;
  if (scope==1 && strlen(name)==66 && !strncmp(name,".tay-new-",9) && name[29]=='-' && nonce(name+30)) {
    char canon[25]; memcpy(canon,name+9,20); memcpy(canon+20,".tay",5);
    if (canonical(canon)) return 2;
  }
  return 0;
}
static int acquire(int existing) {
  if (acquired || !need(2)) return EPROTO;
  strict_mode=(int)number(1); validated_fs=(int)number(1);
  if (strict_mode>1 || validated_fs>1) return EINVAL;
  if (existing) {
    if (!need(4)) return EPROTO;
    directory_limit=(uint32_t)number(4);
    if (!directory_limit) return EINVAL;
  }
#ifndef __linux__
  if (strict_mode) return ENOTSUP;
#endif
  if (strict_mode && !validated_fs) return ENOTSUP;
  int e=string(root_path,sizeof(root_path));
  if (e || pos!=input_n) return e?e:EPROTO;
  if (strict_mode && (!strncmp(root_path,"/tmp/",5) || !strcmp(root_path,"/tmp") ||
      !strncmp(root_path,"/var/tmp/",9) || !strncmp(root_path,"/dev/shm/",9))) return ENOTSUP;
  e=walk_root(existing?0:1,&root_fd,&root_created);
  if (e) return e;
  e=filesystem(root_fd); if (e) return e;
  int created=0;
  if (existing) {
    lock_fd=openat(root_fd,".tay-owner.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  } else {
    lock_fd=openat(root_fd,".tay-owner.lock",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (lock_fd>=0) created=1;
    else if (errno==EEXIST) lock_fd=openat(root_fd,".tay-owner.lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC);
  }
  if (lock_fd<0) return errno;
  struct stat s;
  e=checked_regular(lock_fd,root_fd,".tay-owner.lock",&s); if (e) return e;
  if (flock(lock_fd,LOCK_EX|LOCK_NB)<0) return errno;
  acquired=1;
  inspection_only=existing;
  if (!existing) {
    e=rename_capability(); if (e) return e;
    if (fsync(root_fd)<0) return errno;
    if (created && fsync(lock_fd)<0) return errno;
    if (created && fsync(root_fd)<0) return errno;
  }
  e=open_segments(); if (e && e!=ENOENT) return e;
  put(root_created,1); put(filesystem_type,8); put((uint64_t)getpid(),8);
  return check_paths();
}
/* Promotion keeps every ownership FD. Mode 2 walks/syncs existing ancestors
 * without granting mkdir permission, even if an external path disappears. */
static int enable_mutations(void) {
  if (!inspection_only || read_fd>=0 || write_fd>=0) return EBUSY;
  int e=check_paths(); if (e) return e;
  e=filesystem(root_fd); if (e) return e;
  if (segments_fd<0) return ENOENT;
  e=filesystem(segments_fd); if (e) return e;
  e=rename_capability(); if (e) return e;
  int current=-1, created=0;
  e=walk_root(2,&current,&created); if (e) return e;
  struct stat pinned, now;
  if (fstat(root_fd,&pinned)<0 || fstat(current,&now)<0) e=errno;
  else if (!same(&pinned,&now)) e=ESTALE;
  if (close(current)<0 && !e) e=errno;
  if (e) return e;
  if (promotion_sync(lock_fd,242)<0 || promotion_sync(root_fd,243)<0 ||
      promotion_sync(segments_fd,244)<0) return errno;
  e=check_paths(); if (e) return e;
  inspection_only=0;
  return 0;
}
static int list_directory(void) {
  if (!need(1)) return EPROTO;
  int scope=(int)number(1), fd=scope_fd(scope);
  if (fd<0) return scope==1?ENOENT:EINVAL;
  /* A new open file description avoids shared directory offsets with dup(). */
  int copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if (copy<0) return errno;
  DIR *dir=fdopendir(copy); if (!dir) { int e=errno; close(copy); return e; }
  put(0,4); uint32_t count=0; struct dirent *ent; int e=0;
  errno=0;
  while ((ent=readdir(dir))) {
    if (!strcmp(ent->d_name,".") || !strcmp(ent->d_name,"..")) continue;
    if (count>=directory_limit) { e=EFBIG; break; }
    size_t n=strlen(ent->d_name); struct stat s;
    if (output_n+n+39>PACKET_MAX-23) { e=EFBIG; break; }
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
  if (read_fd>=0 || !need(1)) return EBUSY;
  read_scope=(int)number(1); int fd=scope_fd(read_scope);
  int e=string(read_name,sizeof(read_name));
  if (e || !basename_ok(read_name) || fd<0) return e?e:EINVAL;
  read_fd=openat(fd,read_name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  if (read_fd<0) return errno;
  e=checked_regular(read_fd,fd,read_name,&read_identity);
  if (e) { close(read_fd); read_fd=-1; return e; }
  stat_out(&read_identity); return 0;
}
static int validate_read(void) {
  struct stat now;
  if (read_fd<0) return EBADF;
  int e=checked_regular(read_fd,scope_fd(read_scope),read_name,&now);
  if (e) return e;
  return same(&now,&read_identity) && now.st_size==read_identity.st_size ? 0 : ESTALE;
}
static int read_at(void) {
  if (!need(12)) return EPROTO;
  uint64_t off=number(8), n=number(4);
  if (off>SEGMENT_MAX || n>16777244u || off+n>SEGMENT_MAX) return EFBIG;
  int e=validate_read(); if (e) return e;
#ifdef TAY_TEST_FAULTS
  if (fault_now && fault_action==2 && n) n=fault_short<n?fault_short:n-1;
#endif
  ssize_t got=pread(read_fd,output,(size_t)n,(off_t)off);
  if (got<0) return errno;
  output_n=(size_t)got; return validate_read();
}
static int create_stage(void) {
  if (write_fd>=0 || !need(1)) return EBUSY;
  write_scope=(int)number(1); int fd=scope_fd(write_scope);
  int e=string(write_name,sizeof(write_name));
  if (e) return e;
  write_kind=stage_kind(write_scope,write_name);
  if (!write_kind || fd<0) return EINVAL;
  write_fd=openat(fd,write_name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if (write_fd<0) return errno;
  e=checked_regular(write_fd,fd,write_name,&write_identity);
  if (!e) stat_out(&write_identity);
  return e;
}
static int open_active(void) {
  if (write_fd>=0) return EBUSY;
  int e=string(write_name,sizeof(write_name));
  if (e || !need(24) || !canonical(write_name)) return e?e:EINVAL;
  uint64_t size=number(8), dev=number(8), ino=number(8);
  write_scope=1; write_kind=1;
  write_fd=openat(segments_fd,write_name,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  if (write_fd<0) return errno;
  e=checked_regular(write_fd,segments_fd,write_name,&write_identity);
  if (!e && ((uint64_t)write_identity.st_size!=size || (uint64_t)write_identity.st_dev!=dev ||
     (uint64_t)write_identity.st_ino!=ino)) e=ESTALE;
  if (!e && (size<44 || size>SEGMENT_MAX-64)) e=EINVAL;
  if (e) { close(write_fd); write_fd=-1; return e; }
  stat_out(&write_identity); return 0;
}

static int write_at(void) {
  if (write_fd<0 || !need(8)) return EBADF;
  uint64_t off=number(8); size_t n=input_n-pos;
  struct stat s;
  if (fstat(write_fd,&s)<0) return errno;
  if (!n || n>16777244u || off!=(uint64_t)s.st_size || off>SEGMENT_MAX || n>SEGMENT_MAX-off) return EINVAL;
  if (write_kind>1 && (off!=0 || n!=(write_kind==2?44u:28u))) return EINVAL;
  size_t requested=n;
#ifdef TAY_TEST_FAULTS
  if (fault_now && fault_action==2) n=(size_t)(fault_short<n?fault_short:n-1);
#endif
  /* A single filesystem pwrite. No EINTR/short-write retry is legal here. */
  known_written=UINT64_MAX; /* A failed syscall need not prove zero changed bytes. */
  ssize_t result;
#ifdef TAY_TEST_FAULTS
  if (fault_now && fault_action==8) { errno=fault_errno?fault_errno:EIO; result=-1; }
  else
#endif
  result=pwrite(write_fd,input+pos,n,(off_t)off);
  if (result<0) return errno;
  known_written=(uint64_t)result;
  if ((size_t)result!=requested) {
#ifdef TAY_TEST_FAULTS
    if (fault_now && fault_action==2) return fault_errno?fault_errno:EIO;
#endif
    return EIO;
  }
  if (fstat(write_fd,&s)<0) return errno;
  if ((uint64_t)s.st_size!=off+requested) return ESTALE;
  unsigned char *readback=malloc(requested); if (!readback) return ENOMEM;
  ssize_t got=pread(write_fd,readback,requested,(off_t)off);
  int e=got<0?errno:((size_t)got!=requested || memcmp(readback,input+pos,requested)?EIO:0);
  free(readback);
  pos=input_n;
  if (!e) stat_out(&s);
  return e;
}
static int publish(void) {
  if (write_fd>=0 || !need(1)) return EBUSY;
  int scope=(int)number(1), fd=scope_fd(scope);
  char source[256], target[256];
  int e=string(source,sizeof(source)); if (e) return e;
  e=string(target,sizeof(target)); if (e || !need(16)) return e?e:EPROTO;
  uint64_t dev=number(8), ino=number(8);
  int kind=stage_kind(scope,source);
  if (fd<0 || !kind || (scope==0 && strcmp(target,"STORE")) ||
      (scope==1 && (!canonical(target) || strncmp(source+9,target,20)))) return EINVAL;
  struct stat s, after;
  if (fstatat(fd,source,&s,AT_SYMLINK_NOFOLLOW)<0) return errno;
  if (!S_ISREG(s.st_mode) || s.st_nlink!=1 || (uint64_t)s.st_dev!=dev || (uint64_t)s.st_ino!=ino ||
      s.st_size!=(kind==2?44:28)) return ESTALE;
  if (no_replace(fd,source,target)<0) return errno;
  if (fstatat(fd,target,&after,AT_SYMLINK_NOFOLLOW)<0) return errno;
  return same(&s,&after) && after.st_nlink==1 ? 0 : ESTALE;
}
static int dispatch(unsigned op) {
  int e=0, fd;
  if (op==ACQUIRE || op==ACQUIRE_EXISTING) {
    if (poisoned || root_fd>=0) return ECANCELED;
    return acquire(op==ACQUIRE_EXISTING);
  }
  if (op==SHUTDOWN) {
    int descriptors[]={write_fd,read_fd,segments_fd,root_fd,lock_fd};
    for (size_t i=0;i<sizeof(descriptors)/sizeof(descriptors[0]);i++) {
      if (descriptors[i]>=0 && close(descriptors[i])<0) _exit(94);
    }
    write_fd=read_fd=segments_fd=root_fd=lock_fd=-1; acquired=0;
    return 0;
  }
#ifdef TAY_TEST_FAULTS
  if (op==FAULT) {
    if (!need(18)) return EPROTO;
    fault_op=(int)number(1); fault_n=(int)number(4); fault_action=(int)number(1);
    fault_errno=(int)number(4); fault_short=number(8); return 0;
  }
#endif
  if (poisoned) return ECANCELED;
  e=check_paths(); if (e) return e;
  if (op==ENABLE_MUTATIONS) return enable_mutations();
  if (inspection_only && op!=LIST && op!=OPEN_READ && op!=READ_AT &&
      op!=CLOSE_READ && op!=CHECK && op!=INFO) return EPERM;
  switch (op) {
    case LIST: return list_directory();
    case MKDIR_SEGMENTS:
      if (segments_fd>=0) return EEXIST;
      if (mkdirat(root_fd,"segments",0700)<0) return errno;
      return open_segments();
    case OPEN_READ: return open_read();
    case READ_AT: return read_at();
    case CLOSE_READ:
      e=validate_read(); fd=read_fd; read_fd=-1;
      if (fd>=0 && close(fd)<0 && !e) e=errno;
      return e;
    case CREATE_STAGE: return create_stage();
    case OPEN_ACTIVE: return open_active();
    case WRITE_AT: return write_at();
    case SYNC_FILE: return write_fd<0?EBADF:fsync(write_fd)<0?errno:0;
    case CLOSE_WRITE:
      fd=write_fd; write_fd=-1; write_kind=0;
      return fd<0?EBADF:close(fd)<0?errno:0;
    case PUBLISH: return publish();
    case SYNC_DIR:
      if (!need(1)) return EPROTO;
      fd=scope_fd((int)number(1)); return fd<0?ENOENT:fsync(fd)<0?errno:0;
    case CHECK: return check_paths();
    case INFO:
      put((uint64_t)getpid(),8); put(write_fd<0?0:write_kind,1); put(read_fd>=0,1);
      put(filesystem_type,8); put(ancestor_syncs,4); return 0;
    case SYNC_READ:
      e=validate_read(); return e?e:fsync(read_fd)<0?errno:0;
    default: return EPROTO;
  }
}
/* Reject malformed control messages before any filesystem operation. */
static int validate_request(unsigned op) {
  char name[PATH_MAX]; int e=0;
  switch (op) {
    case ACQUIRE: case ACQUIRE_EXISTING:
      if (!need(op==ACQUIRE_EXISTING?6:2)) return EPROTO;
      pos+=op==ACQUIRE_EXISTING?6:2; e=string(name,sizeof(name)); break;
    case LIST: case SYNC_DIR:
      if (!need(1)) return EPROTO;
      pos++; break;
    case OPEN_READ: case CREATE_STAGE:
      if (!need(1)) return EPROTO;
      pos++; e=string(name,256); break;
    case READ_AT:
      if (!need(12)) return EPROTO;
      pos+=12; break;
    case OPEN_ACTIVE:
      e=string(name,256); if (e) return e;
      if (!need(24)) return EPROTO;
      pos+=24; break;
    case WRITE_AT:
      if (!need(9) || input_n-pos>16777244u+8u) return EPROTO;
      pos=input_n; break;
    case PUBLISH:
      if (!need(1)) return EPROTO;
      pos++; e=string(name,256); if (e) return e;
      e=string(name,256); if (e) return e;
      if (!need(16)) return EPROTO;
      pos+=16; break;
    case MKDIR_SEGMENTS: case CLOSE_READ: case SYNC_FILE: case CLOSE_WRITE:
    case CHECK: case INFO: case SYNC_READ: case SHUTDOWN: case ENABLE_MUTATIONS: break;
#ifdef TAY_TEST_FAULTS
    case FAULT:
      if (!need(18)) return EPROTO;
      pos+=18; break;
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
  for (;;) {
    unsigned char size_bytes[4];
    if (transfer(STDIN_FILENO,size_bytes,4,0)<0) break;
    uint32_t size=0; for (int i=0;i<4;i++) size=(size<<8)|size_bytes[i];
    if (size<10 || size>PACKET_MAX) break;
    unsigned char *packet=malloc(size); if (!packet) break;
    if (transfer(STDIN_FILENO,packet,size,0)<0) { free(packet); break; }
    input=packet; input_n=size; pos=0;
    unsigned version=(unsigned)number(1), op=(unsigned)number(1); uint64_t id=number(8);
    output_n=0; known_written=0;
    int e=0;
#ifdef TAY_TEST_FAULTS
    fault_now=(op==(unsigned)fault_op && fault_n>0 && --fault_n==0);
    if (fault_now && fault_action==1) e=fault_errno?fault_errno:EIO;
    else if (fault_now && fault_action==5) _exit(95);
    else if (fault_now && fault_action==6) { if (lock_fd>=0) close(lock_fd); lock_fd=-1; }
#endif
    if (!e) e=version==1?validate_request(op):EPROTO;
    if (!e) { pos=10; e=dispatch(op); }
    if (!e && pos!=input_n) e=EPROTO;
    if (!e && acquired) e=check_paths();
    if (e && op!=LIST && op!=OPEN_READ && op!=READ_AT && op!=CLOSE_READ) poisoned=1;
#ifdef TAY_TEST_FAULTS
    if (fault_now && fault_action==3) _exit(93);
    if (fault_now && fault_action==4) { free(packet); continue; }
    if (fault_now && fault_action==7) id^=1;
#endif
    if (e) {
      const char *reason=error_name(e); output_n=strlen(reason); memcpy(output,reason,output_n);
    }
    size_t body_n=output_n;
    unsigned char *reply=malloc(body_n+27); if (!reply) { free(packet); break; }
    uint32_t total=(uint32_t)body_n+23;
    for (int i=0;i<4;i++) reply[i]=(unsigned char)(total>>((3-i)*8));
    reply[4]=1; reply[5]=(unsigned char)op;
    for (int i=0;i<8;i++) reply[6+i]=(unsigned char)(id>>((7-i)*8));
    reply[14]=e?1:0;
    for (int i=0;i<4;i++) reply[15+i]=(unsigned char)((uint32_t)e>>((3-i)*8));
    for (int i=0;i<8;i++) reply[19+i]=(unsigned char)(known_written>>((7-i)*8));
    memcpy(reply+27,output,body_n);
    int sent=transfer(STDOUT_FILENO,reply,body_n+27,1);
    free(reply); free(packet);
    if (sent<0 || op==SHUTDOWN) break;
  }
  /* Process exit closes every pinned descriptor and releases flock together. */
  return 0;
}
