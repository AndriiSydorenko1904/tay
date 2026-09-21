"""Protocol v1 framing and JSON validation.

The SDK deliberately keeps this module dependency-free so it can double as a
small reference implementation for clients in other languages.  Frames are a
four byte, unsigned big-endian payload length followed by UTF-8 JSON.
"""

from __future__ import annotations

import asyncio
import json
import math
import struct
from collections.abc import Mapping
from typing import Any

from .errors import ProtocolError, ValidationError

PROTOCOL_VERSION = 1
DEFAULT_MAX_FRAME_BYTES = 1_048_576
DEFAULT_MAX_JSON_DEPTH = 32
DEFAULT_MAX_COLLECTION_ITEMS = 10_000
DEFAULT_MAX_TASK_NAME_BYTES = 255


def _json_constant(value: str) -> None:
    raise ProtocolError(f"JSON constant {value!r} is not permitted")


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError(f"duplicate JSON object key {key!r}")
        result[key] = value
    return result


def normalize_json(
    value: Any,
    *,
    max_depth: int = DEFAULT_MAX_JSON_DEPTH,
    max_collection_items: int = DEFAULT_MAX_COLLECTION_ITEMS,
    _depth: int = 0,
) -> Any:
    """Return a detached JSON-safe representation of *value*.

    Protocol values intentionally have a small vocabulary: null, booleans,
    finite numbers, strings, lists, and objects with string keys.  Arbitrary
    Python objects (including tuples, datetimes, bytes, and ORM instances) are
    rejected before a request ever reaches the socket.
    """

    if _depth > max_depth:
        raise ValidationError(f"JSON value exceeds maximum nesting depth ({max_depth})")

    # bool is an int subclass, so it must be considered first.
    if value is None or type(value) is bool or type(value) is str or type(value) is int:
        return value

    if type(value) is float:
        if not math.isfinite(value):
            raise ValidationError("JSON numbers must be finite")
        return value

    if type(value) is list:
        if len(value) > max_collection_items:
            raise ValidationError(
                f"JSON list has more than {max_collection_items} items"
            )
        return [
            normalize_json(
                item,
                max_depth=max_depth,
                max_collection_items=max_collection_items,
                _depth=_depth + 1,
            )
            for item in value
        ]

    if isinstance(value, Mapping):
        if len(value) > max_collection_items:
            raise ValidationError(
                f"JSON object has more than {max_collection_items} entries"
            )

        normalized: dict[str, Any] = {}
        for key, item in value.items():
            if type(key) is not str:
                raise ValidationError("JSON object keys must be strings")
            normalized[key] = normalize_json(
                item,
                max_depth=max_depth,
                max_collection_items=max_collection_items,
                _depth=_depth + 1,
            )
        return normalized

    raise ValidationError(
        f"{type(value).__name__} is not JSON-safe; pass IDs and plain JSON values instead"
    )


def json_bytes(value: Any) -> bytes:
    """Encode a previously validated JSON value deterministically."""

    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"value cannot be encoded as JSON: {exc}") from exc


def encoded_json_size(value: Any) -> int:
    """Return the UTF-8 size of a JSON-safe value."""

    return len(json_bytes(normalize_json(value)))


def validate_task_name(name: str) -> str:
    if type(name) is not str or not name:
        raise ValidationError("task name must be a non-empty string")
    if len(name.encode("utf-8")) > DEFAULT_MAX_TASK_NAME_BYTES:
        raise ValidationError(
            f"task name exceeds {DEFAULT_MAX_TASK_NAME_BYTES} UTF-8 bytes"
        )
    if any(ord(character) < 0x20 for character in name):
        raise ValidationError("task name cannot contain control characters")
    return name


def validate_envelope(
    envelope: Mapping[str, Any], *, incoming: bool = False
) -> dict[str, Any]:
    """Validate the stable envelope fields and return a detached copy.

    ``v`` is accepted on incoming messages only as a short-lived compatibility
    convenience for early v1 prototypes; all SDK-generated frames use the
    documented ``version`` spelling.
    """

    normalized = normalize_json(envelope)
    if not isinstance(normalized, dict):  # pragma: no cover - normalize guarantees this
        raise ProtocolError("protocol envelope must be an object")

    version = normalized.get("version")
    if incoming and version is None:
        version = normalized.get("v")
    if version != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported protocol version {version!r}")

    message_type = normalized.get("type")
    if type(message_type) is not str or not message_type:
        raise ProtocolError("protocol envelope requires a non-empty string type")
    if len(message_type.encode("utf-8")) > 64:
        raise ProtocolError("protocol message type is too long")

    request_id = normalized.get("request_id")
    if type(request_id) is not str or not request_id:
        raise ProtocolError("protocol envelope requires a non-empty string request_id")
    if isinstance(request_id, str) and len(request_id.encode("utf-8")) > 128:
        raise ProtocolError("request_id is too long")

    return normalized


def encode_frame(
    envelope: Mapping[str, Any], *, max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES
) -> bytes:
    """Encode one protocol envelope into a length-prefixed frame."""

    if not isinstance(max_frame_bytes, int) or max_frame_bytes < 1:
        raise ValueError("max_frame_bytes must be a positive integer")
    normalized = validate_envelope(envelope)
    payload = json_bytes(normalized)
    if not payload or len(payload) > max_frame_bytes:
        raise ProtocolError(
            f"protocol payload size {len(payload)} exceeds limit {max_frame_bytes}"
        )
    return struct.pack(">I", len(payload)) + payload


def decode_payload(
    payload: bytes, *, max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES
) -> dict[str, Any]:
    """Decode and validate a raw JSON frame payload."""

    if not payload or len(payload) > max_frame_bytes:
        raise ProtocolError("invalid protocol frame length")
    try:
        raw = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProtocolError("protocol frame is not UTF-8") from exc
    try:
        parsed = json.loads(
            raw,
            object_pairs_hook=_no_duplicate_keys,
            parse_constant=_json_constant,
        )
    except (json.JSONDecodeError, ProtocolError) as exc:
        if isinstance(exc, ProtocolError):
            raise
        raise ProtocolError("protocol frame contains malformed JSON") from exc
    if not isinstance(parsed, dict):
        raise ProtocolError("protocol frame must contain a JSON object")
    return validate_envelope(parsed, incoming=True)


async def read_frame(
    reader: asyncio.StreamReader, *, max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES
) -> dict[str, Any]:
    """Read exactly one bounded frame from an asyncio stream."""

    try:
        header = await reader.readexactly(4)
    except asyncio.IncompleteReadError as exc:
        raise ConnectionError("socket closed while reading protocol header") from exc
    length = struct.unpack(">I", header)[0]
    if length == 0 or length > max_frame_bytes:
        raise ProtocolError(
            f"protocol frame length {length} is outside 1..{max_frame_bytes}"
        )
    try:
        payload = await reader.readexactly(length)
    except asyncio.IncompleteReadError as exc:
        raise ConnectionError("socket closed while reading protocol payload") from exc
    return decode_payload(payload, max_frame_bytes=max_frame_bytes)
