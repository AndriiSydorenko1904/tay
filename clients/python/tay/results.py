"""Shared bounded waiting for a result; waiting never cancels the remote job."""

from __future__ import annotations

import asyncio
from typing import Any, Protocol

from .errors import ServerError
from .validation import positive_finite


class ResultHandle(Protocol):
    @property
    def id(self) -> str: ...
    async def result(self) -> Any: ...


async def wait_result(
    handle: ResultHandle, *, timeout: float, poll_interval: float
) -> Any:
    timeout = positive_finite(timeout, "timeout")
    poll_interval = positive_finite(poll_interval, "poll_interval")
    try:
        async with asyncio.timeout(timeout):
            while True:
                try:
                    return await handle.result()
                except ServerError as exc:
                    if exc.code != "result_not_ready":
                        raise
                await asyncio.sleep(poll_interval)
    except TimeoutError as exc:
        raise TimeoutError(
            f"Tay job {handle.id!r} did not complete within {timeout:g}s"
        ) from exc
