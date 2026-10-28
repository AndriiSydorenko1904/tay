"""Transport-independent validation for job submissions."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from .errors import ValidationError
from .protocol import normalize_json

DURABILITY_MODES = frozenset({"persistent", "volatile"})


def validate_durability(value: Any) -> None:
    if value is not None and (
        not isinstance(value, str) or value not in DURABILITY_MODES
    ):
        raise ValidationError(f"durability must be one of {sorted(DURABILITY_MODES)}")


def job_arguments(args: Mapping[str, Any] | None, *, operation: str) -> dict[str, Any]:
    if args is None:
        args = {}
    if not isinstance(args, Mapping):
        raise ValidationError(f"{operation} args must be a JSON object")
    return normalize_json(args)


def merge_enqueue_options(
    options: Mapping[str, Any] | None,
    keywords: Mapping[str, Any],
    durability: str | None = None,
) -> dict[str, Any]:
    if options is not None and not isinstance(options, Mapping):
        raise ValidationError("enqueue options must be a mapping")
    merged = dict(options) if options is not None else {}
    overlap = merged.keys() & keywords.keys()
    if overlap:
        raise ValidationError(f"enqueue option supplied twice: {min(overlap)}")
    merged.update(keywords)
    if durability is not None:
        if "durability" in merged:
            raise ValidationError("enqueue option supplied twice: durability")
        merged["durability"] = durability
    backoff = merged.get("backoff")
    if backoff is not None and (
        not isinstance(backoff, str) or backoff != "exponential"
    ):
        raise ValidationError("Protocol v1 supports only backoff='exponential'")
    validate_durability(merged.get("durability"))
    return merged


def enqueue_payload(
    task_name: str,
    args: Mapping[str, Any] | None,
    options: Mapping[str, Any] | None,
    keywords: Mapping[str, Any],
    durability: str | None,
) -> dict[str, Any]:
    """Build a payload for a task name validated by the producer's API."""
    arguments = job_arguments(args, operation="enqueue")
    merged = merge_enqueue_options(options, keywords, durability)
    return {"task": task_name, "args": arguments, "options": normalize_json(merged)}
