"""Task invocation and result/error limits shared by socket and HTTP workers.

Cancellation propagates to the transport, which owns execution acknowledgement
and settlement. Synchronous calls stay in their thread until they finish.
"""

from __future__ import annotations

import asyncio
import inspect
import traceback
from collections.abc import Callable, Mapping
from typing import Any

from .errors import ResultTooLarge, ValidationError
from .protocol import json_bytes, normalize_json
from .task import Task


def _result_too_large(size: int, limit: int) -> Exception:
    return ResultTooLarge(f"task result is {size} bytes; limit is {limit} bytes")


async def run_task(
    task: Task,
    arguments: Mapping[str, Any],
    *,
    synchronous: bool,
    max_result_bytes: int,
    size_error: Callable[[int, int], Exception] = _result_too_large,
    on_awaitable: Callable[[], None] | None = None,
) -> Any:
    if synchronous:
        result = await asyncio.to_thread(task._call_from_arguments, arguments)
    else:
        result = task._call_from_arguments(arguments)

    # Both async functions and synchronous callables can return an awaitable.
    if inspect.isawaitable(result):
        # A thread may have finished by returning a coroutine. From here on,
        # remote cancellation can safely interrupt the loop-owned execution.
        if on_awaitable is not None:
            on_awaitable()
        result = await result
    result = normalize_json(result)
    size = len(json_bytes(result))
    if size > max_result_bytes:
        raise size_error(size, max_result_bytes)
    return result


def cancel_async_execution(
    execution: asyncio.Task[Any] | None, synchronous: bool
) -> None:
    if execution is not None and not synchronous:
        execution.cancel()


def error_details(
    exc: BaseException,
    *,
    fallback_message: bool = False,
    max_type_characters: int | None = None,
    max_message_characters: int | None = None,
) -> dict[str, Any]:
    message = str(exc)
    if fallback_message and not message:
        message = type(exc).__name__
    return {
        "type": type(exc).__name__[:max_type_characters],
        "message": message[:max_message_characters],
    }


def bounded_error(
    exc: BaseException, *, max_bytes: int, include_traceback: bool
) -> dict[str, Any]:
    if max_bytes < 2:
        raise ValidationError("error byte limit must fit a JSON object")
    error = error_details(exc, fallback_message=True)
    if include_traceback:
        error["traceback"] = "".join(
            traceback.format_exception(type(exc), exc, exc.__traceback__)
        )
    # Every field is text. Shrink all fields, including exception class names,
    # until the actual UTF-8 JSON fits; even the smallest fallback is measured.
    while len(json_bytes(error)) > max_bytes:
        for field in ("traceback", "message", "type"):
            if error.get(field):
                error[field] = _truncate_text(error[field])
                break
        else:
            return {}
    return error


def _truncate_text(value: str) -> str:
    if len(value) <= 2:
        return ""
    return value[: max(1, len(value) // 2 - 1)] + "…"
