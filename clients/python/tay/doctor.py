"""Read-only transport diagnostics; never registers workers or submits jobs."""

from __future__ import annotations

import asyncio
import os
import stat
from pathlib import Path
from typing import Any

from .errors import ServerError
from .http import TayHTTP
from .socket_path import discover_socket_path
from .validation import positive_finite


async def diagnose_socket(
    path: str | None = None, *, timeout: float = 5.0
) -> dict[str, Any]:
    timeout = positive_finite(timeout, "timeout")
    resolved, source = discover_socket_path(path)
    report: dict[str, Any] = {
        "transport": "socket",
        "path": resolved,
        "source": source,
        "uid": os.geteuid(),
        "gid": os.getegid(),
        "groups": os.getgroups(),
        "ok": False,
    }
    try:
        info = os.stat(resolved)
        report.update(
            socket_uid=info.st_uid,
            socket_gid=info.st_gid,
            socket_mode=oct(stat.S_IMODE(info.st_mode)),
            parent_searchable=os.access(str(Path(resolved).parent), os.X_OK),
            socket_writable=os.access(resolved, os.W_OK),
        )
        if not stat.S_ISSOCK(info.st_mode):
            report["error"] = "selected path is not a Unix socket"
            return report
        async with asyncio.timeout(timeout):
            _reader, writer = await asyncio.open_unix_connection(resolved)
            writer.close()
            await writer.wait_closed()
        report["ok"] = True
    except (OSError, TimeoutError) as exc:
        report["error"] = type(exc).__name__
        report["hint"] = (
            "check listener, shared socket volume, UID/GID and directory search/socket write permissions"
        )
    return report


async def diagnose_http(
    base_url: str, *, timeout: float = 5.0, **tls: Any
) -> dict[str, Any]:
    timeout = positive_finite(timeout, "timeout")
    report: dict[str, Any] = {"transport": "http", "ok": False}
    # TayHTTP validates origin/mTLS and disables redirects and proxy inheritance.
    # Credential paths, passphrases and certificate contents never enter output.
    try:
        async with TayHTTP(base_url, request_timeout=timeout, **tls) as client:
            report.update(
                origin=client.base_url, tls=client.base_url.startswith("https://")
            )
            async with asyncio.timeout(timeout):
                health = await client._request("GET", "/health")
            if health.get("type") == "health" and health.get("state") in (
                "ready",
                "compacting",
            ):
                report.update(state=health["state"], ok=True)
            else:
                report["error"] = "invalid_health_response"
    except Exception as exc:  # noqa: BLE001 - diagnostics return a bounded failure category
        report["error"] = (
            exc.code if isinstance(exc, ServerError) else type(exc).__name__
        )
        report["hint"] = (
            "check origin, listener readiness and mTLS credential configuration"
        )
    return report
