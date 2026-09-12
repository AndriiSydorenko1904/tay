#!/usr/bin/env python3
"""Exclusive cold byte-copy/restore. Catalogs are external evidence, not Tay state."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
import secrets
import stat
import sys
from contextlib import ExitStack


class Refused(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, _message):
        self.exit(2, '{"result":"refused","reason":"invalid_arguments"}\n')


def require(condition, code):
    if not condition:
        raise Refused(code)


def absolute(path):
    require(".." not in path.split(os.sep), "unsafe_path")
    path = os.path.abspath(path)
    require(path != os.sep and len(os.fsencode(path)) <= 4095, "unsafe_path")
    path.encode("utf-8", "strict")
    return path


def name_valid(name):
    require(name not in ("", ".", "..") and "/" not in name and "\0" not in name, "unsafe_name")
    name.encode("utf-8", "strict")


def keep(stack, fd):
    stack.callback(os.close, fd)
    return fd


def directory(stack, path):
    """Pin every ancestor; never follow an ancestor or leaf symlink."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = keep(stack, os.open(os.sep, flags))
    chain = [fd]
    for component in path.split(os.sep)[1:]:
        name_valid(component)
        fd = keep(stack, os.open(component, flags, dir_fd=fd))
        chain.append(fd)
    return fd, chain


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def same_inode(first, second):
    return (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino)


def verify_chain(path, chain):
    for index, component in enumerate(path.split(os.sep)[1:]):
        current = os.stat(component, dir_fd=chain[index], follow_symlinks=False)
        require(stat.S_ISDIR(current.st_mode) and same_inode(current, os.fstat(chain[index + 1])),
                "ancestor_changed")


def regular(stack, folder, name):
    # Reject a FIFO/device replacement after lookup without blocking on open.
    fd = keep(stack, os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                             dir_fd=folder))
    info = os.fstat(fd)
    named = os.stat(name, dir_fd=folder, follow_symlinks=False)
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "unsafe_file")
    require(identity(info) == identity(named), "source_changed")
    return fd, info


def inventory(root, segments, max_files, max_bytes):
    result = {}
    count, byte_count = 0, 0
    for prefix, folder in (("", root), ("segments/", segments)):
        with os.scandir(folder) as entries:
            for entry in entries:
                count += 1
                require(count <= max_files, "file_budget")
                name = entry.name
                name_valid(name)
                info = entry.stat(follow_symlinks=False)
                if prefix == "" and name == "segments":
                    require(stat.S_ISDIR(info.st_mode), "missing_segments")
                    continue
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "unsafe_file")
                byte_count += info.st_size
                require(byte_count <= max_bytes, "byte_budget")
                result[prefix + name] = identity(info)
    require("STORE" in result and ".tay-owner.lock" in result, "missing_metadata")
    require(any(key.startswith("segments/") and key.endswith(".tay") for key in result), "missing_history")
    return result


def external_chain(chain, source_directories):
    # Lexically distinct bind-mount paths can still enter the source STORE.
    require(not any(same_inode(os.fstat(fd), protected)
                    for fd in chain for protected in source_directories),
            "source_directory_alias")


def file_chunks(fd, expected_bytes):
    count = 0
    while chunk := os.read(fd, min(1_048_576, expected_bytes - count + 1)):
        count += len(chunk)
        require(count <= expected_bytes, "source_changed")
        yield chunk
    require(count == expected_bytes, "source_changed")


def hash_file(fd, expected_bytes):
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    for chunk in file_chunks(fd, expected_bytes):
        digest.update(chunk)
    return digest.hexdigest()


def hashes(root, segments, entries):
    result = {}
    for relative, expected in sorted(entries.items()):
        prefix, _, name = relative.rpartition("/")
        with ExitStack() as stack:
            fd, info = regular(stack, segments if prefix else root, name)
            require(identity(info) == expected, "source_changed")
            digest = hash_file(fd, info.st_size)
            require(identity(os.fstat(fd)) == expected, "source_changed")
            result[relative] = {"bytes": info.st_size, "sha256": digest}
    return result


def linux_filesystem(fd):
    require(sys.platform == "linux", "strict_sync_requires_linux")
    libc = ctypes.CDLL(None, use_errno=True)
    buffer = ctypes.create_string_buffer(256)
    require(libc.fstatfs(fd, ctypes.byref(buffer)) == 0, "filesystem_query_failed")
    kind = ctypes.c_long.from_buffer(buffer).value & 0xFFFFFFFF
    require(kind in (0xEF53, 0x58465342, 0x9123683E), "unsupported_filesystem")
    return kind


def no_replace(parent, source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "linux" and hasattr(libc, "renameat2"):
        operation, flag = libc.renameat2, 1  # RENAME_NOREPLACE, Linux UAPI.
    elif sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        operation, flag = libc.renameatx_np, 4  # RENAME_EXCL, Darwin sys/stdio.h.
    else:
        raise Refused("exclusive_publication_unavailable")
    operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    require(operation(parent, os.fsencode(source), parent, os.fsencode(destination), flag) == 0,
            "exclusive_publication_failed")


def write_all(fd, data):
    while data:
        count = os.write(fd, data)
        require(count > 0, "copy_write_failed")
        data = data[count:]


def load_catalog(stack, path, max_files, source_directories):
    parent, chain = directory(stack, os.path.dirname(path))
    external_chain(chain, source_directories)
    fd, info = regular(stack, parent, os.path.basename(path))
    require(info.st_size <= 64 * 1_048_576, "catalog_budget")
    data = b"".join(file_chunks(fd, info.st_size))
    require(identity(os.fstat(fd)) == identity(info), "source_changed")
    catalog = json.loads(data)
    require(isinstance(catalog, dict) and catalog.get("version") == 1 and
            isinstance(catalog.get("files"), dict) and len(catalog["files"]) <= max_files,
            "invalid_catalog")
    return catalog["files"]


def copy(args):
    require(sys.platform in ("linux", "darwin"), "unsupported_platform")
    source, destination, catalog = map(absolute, (args.source, args.destination, args.catalog))
    verify = absolute(args.verify_catalog) if args.verify_catalog else None
    require(args.operation != "restore" or verify is not None, "restore_catalog_required")
    require(args.max_files > 0 and args.max_bytes > 0, "invalid_budget")
    require(os.path.commonpath((source, destination)) not in (source, destination), "overlapping_paths")
    for external in filter(None, (catalog, verify)):
        require(all(os.path.commonpath((external, store)) != store for store in (source, destination)),
                "catalog_must_be_external")
    strict = args.durability == "sync"
    require(not strict or args.validated_filesystem, "filesystem_validation_required")

    with ExitStack() as stack:
        root, source_ancestors = directory(stack, source)
        lock, lock_info = regular(stack, root, ".tay-owner.lock")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused("source_owned") from None
        segments = keep(stack, os.open("segments", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=root))
        source_directories = (os.fstat(root), os.fstat(segments))
        entries = inventory(root, segments, args.max_files, args.max_bytes)
        expected = hashes(root, segments, entries)
        if verify:
            require(load_catalog(stack, verify, args.max_files, source_directories) == expected, "archive_checksum_mismatch")
        require(inventory(root, segments, args.max_files, args.max_bytes) == entries, "source_changed")
        require(identity(os.stat(".tay-owner.lock", dir_fd=root, follow_symlinks=False)) == identity(lock_info), "lock_changed")

        parent, ancestors = directory(stack, os.path.dirname(destination))
        catalog_parent, catalog_ancestors = directory(stack, os.path.dirname(catalog))
        external_chain(ancestors, source_directories)
        external_chain(catalog_ancestors, source_directories)
        target = os.path.basename(destination)
        require(not os.path.lexists(destination) and not os.path.lexists(catalog), "destination_exists")
        filesystem = None
        if strict:
            linux_filesystem(root)
            linux_filesystem(segments)
            filesystem = linux_filesystem(parent)
            linux_filesystem(catalog_parent)

        # A private sibling is never a file inside any STORE namespace. Every
        # failure leaves it untouched for diagnosis; there is no cleanup delete.
        staging = "." + target + ".tay-copy-" + secrets.token_hex(12)
        os.mkdir(staging, 0o700, dir_fd=parent)
        staged = keep(stack, os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent))
        os.mkdir("segments", 0o700, dir_fd=staged)
        staged_segments = keep(stack, os.open("segments", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=staged))
        synchronized = 0
        # STORE is copied last, but this is not a recovery/repair protocol.
        order = sorted(expected, key=lambda key: (key == "STORE", key))
        for relative in order:
            prefix, _, name = relative.rpartition("/")
            with ExitStack() as files:
                src, info = regular(files, segments if prefix else root, name)
                require(identity(info) == entries[relative], "source_changed")
                dst = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                              0o600, dir_fd=staged_segments if prefix else staged)
                if relative == ".tay-owner.lock":
                    keep(stack, dst)
                    fcntl.flock(dst, fcntl.LOCK_EX | fcntl.LOCK_NB)
                else:
                    keep(files, dst)
                digest = hashlib.sha256()
                for chunk in file_chunks(src, info.st_size):
                    write_all(dst, chunk)
                    digest.update(chunk)
                require(digest.hexdigest() == expected[relative]["sha256"] and
                        identity(os.fstat(src)) == entries[relative], "source_changed")
                if strict:
                    os.fsync(dst)
                    synchronized += 1
        require(inventory(root, segments, args.max_files, args.max_bytes) == entries, "source_changed")
        verify_chain(source, source_ancestors)
        verify_chain(os.path.dirname(destination), ancestors)
        verify_chain(os.path.dirname(catalog), catalog_ancestors)
        require(same_inode(os.stat("segments", dir_fd=root, follow_symlinks=False), os.fstat(segments)),
                "source_changed")
        if strict:
            os.fsync(staged_segments)
            os.fsync(staged)
        no_replace(parent, staging, target)
        if strict:
            # All copied older sealed files are synced above, not merely the
            # highest file. Publication then syncs the complete ancestor chain.
            for fd in reversed(ancestors):
                os.fsync(fd)

        report = {"version": 1, "files": expected, "durability": "synced_copy" if strict else "development_copy",
                  "filesystem": filesystem, "semantic_validation": "required", "source_rpo": "catalog_history_only",
                  "sync_order": ["every_file", "segments_directory", "store_directory", "publication", "ancestors", "external_catalog"] if strict else [],
                  "files_synced": synchronized}
        catalog_fd = keep(stack, os.open(os.path.basename(catalog), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                                         0o600, dir_fd=catalog_parent))
        write_all(catalog_fd, json.dumps(report, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n")
        if strict:
            os.fsync(catalog_fd)
            for fd in reversed(catalog_ancestors):
                os.fsync(fd)
        return {"result": report["durability"], "files": len(expected), "files_synced": synchronized,
                "semantic_validation": "required", "activation": "not_attempted"}


def main():
    parser = Parser(description=__doc__)
    parser.add_argument("operation", choices=("backup", "restore"))
    parser.add_argument("source")
    parser.add_argument("destination")
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--verify-catalog")
    parser.add_argument("--durability", choices=("sync", "development"), default="sync")
    parser.add_argument("--validated-filesystem", action="store_true")
    parser.add_argument("--max-files", type=int, default=100_000)
    parser.add_argument("--max-bytes", type=int, default=10_737_418_240)
    try:
        result = copy(parser.parse_args())
        print(json.dumps(result, sort_keys=True))
        return 0
    except Refused as error:
        print(json.dumps({"result": "refused", "reason": str(error), "action": "preserve_source_and_partial_destination"}), file=sys.stderr)
    except (OSError, ValueError, UnicodeError, TypeError, RecursionError):
        print('{"result":"refused","reason":"io_or_invalid_archive","action":"preserve_source_and_partial_destination"}', file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
