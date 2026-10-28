"""Validation of SDK transport configuration shared by HTTP and UDS."""

from __future__ import annotations

import math
from typing import Any

from .errors import ValidationError


def positive_finite(value: Any, name: str) -> float:
    if type(value) not in (int, float):
        raise ValidationError(f"{name} must be a positive finite number")
    try:
        result = float(value)
    except (OverflowError, ValueError) as exc:
        raise ValidationError(f"{name} must be a positive finite number") from exc
    if not math.isfinite(result) or result <= 0:
        raise ValidationError(f"{name} must be a positive finite number")
    return result


def identifier(value: Any, name: str) -> str:
    if type(value) is not str or not value or "\x00" in value:
        raise ValidationError(
            f"{name} must be a non-empty UTF-8 string of at most 128 bytes"
        )
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise ValidationError(f"{name} must be valid UTF-8") from exc
    if size > 128:
        raise ValidationError(f"{name} must be at most 128 UTF-8 bytes")
    return value
