"""Shared decoding of producer responses, independent of transport."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, cast

from .errors import ProtocolError, RemoteTaskError, ServerError
from .job_options import DURABILITY_MODES as _DURABILITY_MODES
from .task import Durability


def _server_error_from_payload(payload: Any) -> ServerError:
    if isinstance(payload, Mapping):
        code = payload.get("code") or payload.get("type")
        message = payload.get("message") or payload.get("reason")
        if not message:
            message = (
                f"Tay rejected the request ({code})"
                if code
                else "Tay rejected the request"
            )
        if payload.get("remote_task") or (
            isinstance(code, str) and code in {"task_failed", "TaskFailed"}
        ):
            return RemoteTaskError(
                str(message), code=str(code) if code else None, details=dict(payload)
            )
        return ServerError(
            str(message), code=str(code) if code else None, details=dict(payload)
        )
    return ServerError(str(payload))


def _extract_identifier(reply: Mapping[str, Any], field: str, nested_field: str) -> str:
    identifier = reply.get(field)
    if identifier is None:
        nested = reply.get(nested_field)
        if isinstance(nested, Mapping):
            identifier = nested.get("id")
    if type(identifier) is not str or not identifier:
        raise ProtocolError(f"Tay reply did not include a valid {field}")
    return identifier


def _extract_job_durability(reply: Mapping[str, Any]) -> Durability | None:
    job = reply.get("job")
    if isinstance(job, Mapping):
        durability = job.get("durability")
        if isinstance(durability, str) and durability in _DURABILITY_MODES:
            return cast(Durability, durability)
    return None
