"""Transport-independent validation for job submissions."""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from typing import Any, cast

from .errors import ValidationError
from .protocol import normalize_json
from .validation import identifier

DURABILITY_MODES = frozenset({"persistent", "volatile"})


ENQUEUE_OPTION_NAMES = frozenset(
    {
        "id",
        "submission_id",
        "delay",
        "delay_ms",
        "run_at",
        "retries",
        "timeout",
        "timeout_ms",
        "backoff",
        "queue",
        "durability",
    }
)
_MAX_TIME = 9_223_372_036_854_775_807


def _milliseconds(value: Any, maximum: int, minimum: int, name: str) -> None:
    if type(value) not in (int, float) or value < 0:
        raise ValidationError(f"invalid {name}")
    if type(value) is float and not math.isfinite(value):
        raise ValidationError(f"invalid {name}")
    if value > maximum / 1000:
        raise ValidationError(f"invalid {name}")
    # Elixir round/1 rounds positive halfway values away from zero.
    scaled = value * 1000
    converted = (
        math.floor(scaled) + int(scaled - math.floor(scaled) >= 0.5)
        if type(value) is float
        else scaled
    )
    if not minimum <= converted <= maximum:
        raise ValidationError(f"invalid {name}")


def validate_submission_options(options: Mapping[str, Any]) -> None:
    unknown = options.keys() - ENQUEUE_OPTION_NAMES
    if unknown:
        raise ValidationError(f"unsupported enqueue option: {min(unknown, key=str)}")
    validate_execution_options(options)
    job_id = options.get("id")
    submission_id = options.get("submission_id")
    if job_id is not None and (
        type(job_id) is not str
        or not re.fullmatch(r"[0-9a-f]{32}", job_id)
        or int(job_id, 16) == 0
    ):
        raise ValidationError("id must be a nonzero lowercase 128-bit hex ID")
    if submission_id is not None:
        identifier(submission_id, "submission_id")
        if job_id is not None:
            raise ValidationError("id and submission_id cannot be combined")
    delay, delay_ms, run_at = (
        options.get(name) for name in ("delay", "delay_ms", "run_at")
    )
    if delay is not None:
        _milliseconds(delay, _MAX_TIME, 0, "delay")
    if delay_ms is not None and (
        type(delay_ms) is not int or not 0 <= delay_ms <= _MAX_TIME
    ):
        raise ValidationError("invalid delay_ms")
    if delay is not None and delay_ms is not None:
        raise ValidationError("delay and delay_ms cannot be combined")
    if run_at is not None:
        if type(run_at) is not int or not 0 <= run_at <= _MAX_TIME:
            raise ValidationError("invalid run_at")
        if delay is not None or delay_ms is not None:
            raise ValidationError("run_at cannot be combined with delay")
    timeout, timeout_ms = options.get("timeout"), options.get("timeout_ms")
    if timeout is not None:
        _milliseconds(timeout, 86_400_000, 1, "timeout")
    if timeout_ms is not None and (
        type(timeout_ms) is not int or not 1 <= timeout_ms <= 86_400_000
    ):
        raise ValidationError("invalid timeout_ms")
    if timeout is not None and timeout_ms is not None:
        raise ValidationError("timeout and timeout_ms cannot be combined")
    if "queue" in options:
        queue = options["queue"]
        if type(queue) is not str or not queue or "\x00" in queue:
            raise ValidationError("invalid queue")
        try:
            if len(queue.encode("utf-8")) > 255:
                raise ValidationError("queue exceeds 255 UTF-8 bytes")
        except UnicodeEncodeError as exc:
            raise ValidationError("queue must be valid UTF-8") from exc
    if "retries" in options and options["retries"] is None:
        raise ValidationError("retries cannot be null")


def validate_durability(value: Any) -> None:
    if value is not None and (
        not isinstance(value, str) or value not in DURABILITY_MODES
    ):
        raise ValidationError(f"durability must be one of {sorted(DURABILITY_MODES)}")


def validate_execution_options(options: Mapping[str, Any]) -> None:
    retries = options.get("retries")
    if retries is not None and (type(retries) is not int or not 0 <= retries <= 65_534):
        raise ValidationError("retries must be an integer in 0..65534")
    backoff = options.get("backoff")
    if backoff is not None and (
        not isinstance(backoff, str) or backoff != "exponential"
    ):
        raise ValidationError("Protocol v1 supports only backoff='exponential'")
    validate_durability(options.get("durability"))


def job_arguments(args: Mapping[str, Any] | None, *, operation: str) -> dict[str, Any]:
    if args is None:
        args = {}
    if not isinstance(args, Mapping):
        raise ValidationError(f"{operation} args must be a JSON object")
    return cast(dict[str, Any], normalize_json(args))


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
    validate_submission_options(merged)
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
