"""Shared Executor Protocol v1 local Unix-socket discovery contract.

The Elixir runtime implements the same precedence and path layout. Automatic
paths own their final directory; an explicit argument or TAY_SOCKET_PATH only
selects a path and never causes an SDK to alter its parent permissions.
"""

from __future__ import annotations

import os
from collections.abc import Callable, Mapping

from .errors import ValidationError

MAX_SOCKET_PATH_BYTES = 100


def resolve_socket_path(
    explicit: str | os.PathLike[str] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    uid: int | None = None,
    usable_directory: Callable[[str], bool] | None = None,
) -> str:
    """Resolve the Protocol v1 local socket path without creating files.

    Precedence is explicit argument, ``TAY_SOCKET_PATH``, usable
    ``XDG_RUNTIME_DIR``, usable ``TMPDIR``, then ``/tmp/tay-<uid>/tay.sock``.
    The UID component prevents a shared ``TMPDIR`` from creating cross-user
    collisions. The listener creates/chmods only automatic final directories.
    ``environ``/``uid``/``usable_directory`` make the contract testable without
    modifying process-global environment state.
    """

    environment = os.environ if environ is None else environ
    usable = _usable_directory if usable_directory is None else usable_directory

    if explicit is not None:
        return _validated_path(os.fspath(explicit))

    configured = environment.get("TAY_SOCKET_PATH")
    if configured:
        return _validated_path(configured)

    user_id = os.getuid() if uid is None else uid
    if type(user_id) is not int or user_id < 0:
        raise ValidationError(
            "a non-negative Unix UID is required for socket discovery"
        )

    xdg = environment.get("XDG_RUNTIME_DIR")
    if xdg and usable(xdg):
        candidate = _candidate(xdg, "tay", "tay.sock")
        if _valid_path(candidate):
            return candidate

    tmpdir = environment.get("TMPDIR")
    if tmpdir and usable(tmpdir):
        candidate = _candidate(tmpdir, f"tay-{user_id}", "tay.sock")
        if _valid_path(candidate):
            return candidate

    return _validated_path(_candidate("/tmp", f"tay-{user_id}", "tay.sock"))


def _candidate(parent: str, *parts: str) -> str:
    return os.path.abspath(os.path.join(parent, *parts))


def _validated_path(path: str) -> str:
    if not _valid_path(path):
        raise ValidationError(
            "socket_path must be an absolute UTF-8 path of at most 100 bytes"
        )
    normalized = os.path.abspath(path)
    if not _valid_path(normalized):
        raise ValidationError(
            "socket_path must be an absolute UTF-8 path of at most 100 bytes"
        )
    return normalized


def _valid_path(path: str) -> bool:
    if (
        not isinstance(path, str)
        or not path
        or not os.path.isabs(path)
        or "\x00" in path
    ):
        return False
    try:
        return len(path.encode("utf-8")) <= MAX_SOCKET_PATH_BYTES
    except UnicodeEncodeError:
        return False


def _usable_directory(path: str) -> bool:
    return os.path.isdir(path) and os.access(path, os.W_OK | os.X_OK)
