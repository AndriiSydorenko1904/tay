"""Shared schedule validation, handles and producer API for both transports."""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from .errors import ModeError, ProtocolError, ValidationError
from .job_options import job_arguments, merge_enqueue_options
from .protocol import normalize_json, validate_task_name
from .responses import _extract_identifier
from .validation import identifier

if TYPE_CHECKING:
    from .task import Task

_OVERLAP = frozenset({"allow", "skip", "queue"})
_CATCH_UP = frozenset({"latest", "all"})
_TIMEZONE = re.compile(r"^(?:UTC|Z|[+-](?:[01]\d|2[0-3])(?::[0-5]\d)?)$")
_MAX_TIME = 9_223_372_036_854_775_807


def validate_cron(cron: Any) -> None:
    if type(cron) is not str or not cron.strip():
        raise ValidationError(
            "cron must be a non-empty string no longer than 128 bytes"
        )
    try:
        size = len(cron.encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise ValidationError("cron must be valid UTF-8") from exc
    if size > 128:
        raise ValidationError("cron must be no longer than 128 bytes")


def validate_every(value: Mapping[str, Any]) -> dict[str, int | float]:
    if not isinstance(value, Mapping):
        raise ValidationError("every must be a mapping such as {'minutes': 4}")
    units = {"seconds": 1000, "minutes": 60_000, "hours": 3_600_000, "days": 86_400_000}
    if set(value) - units.keys():
        raise ValidationError("every only accepts seconds, minutes, hours, or days")
    present = [(key, item) for key, item in value.items() if item is not None]
    if len(present) != 1:
        raise ValidationError("every requires exactly one positive time unit")
    unit, amount = present[0]
    if type(amount) not in (int, float) or amount <= 0:
        raise ValidationError(f"every.{unit} must be a positive finite number")
    if type(amount) is float and not math.isfinite(amount):
        raise ValidationError(f"every.{unit} must be finite")
    scaled = amount * units[unit]
    if not 0.5 <= scaled <= _MAX_TIME:
        raise ValidationError(
            "every interval is outside the supported millisecond range"
        )
    return {unit: amount}


def validate_schedule_options(
    *,
    declaration_id: str | None,
    timezone: str = "+00",
    catch_up: str = "latest",
    overlap: str | None = None,
    delay: float | None = None,
    start_at: int | None = None,
) -> None:
    if declaration_id is not None:
        identifier(declaration_id, "declaration_id")
    if type(timezone) is not str or not _TIMEZONE.fullmatch(timezone):
        raise ValidationError(
            "timezone must be UTC, Z, or an offset such as +01 or -02:30"
        )
    if not isinstance(catch_up, str) or catch_up not in _CATCH_UP:
        raise ValidationError(f"catch_up must be one of {sorted(_CATCH_UP)}")
    if overlap is not None and (
        not isinstance(overlap, str) or overlap not in _OVERLAP
    ):
        raise ValidationError(f"overlap must be one of {sorted(_OVERLAP)}")
    if delay is not None:
        if type(delay) not in (int, float) or delay < 0:
            raise ValidationError(
                "delay must be a finite non-negative number of seconds"
            )
        if type(delay) is float and not math.isfinite(delay):
            raise ValidationError(
                "delay must be a finite non-negative number of seconds"
            )
        if delay > _MAX_TIME / 1000:
            raise ValidationError("delay is outside the supported millisecond range")
    if start_at is not None and (
        type(start_at) is not int or not 0 <= start_at <= _MAX_TIME
    ):
        raise ValidationError(
            "start_at must be a supported non-negative UTC millisecond timestamp"
        )
    if delay is not None and start_at is not None:
        raise ValidationError("pass either delay or start_at, not both")


@dataclass(frozen=True)
class ScheduleHandle:
    """Stable durable schedule reference usable across Engine restarts."""

    id: str
    _tay: Scheduling

    async def cancel(self) -> Any:
        reply = await self._tay._cancel_schedule(self.id)
        return reply.get("schedule", reply.get("status", reply))

    async def status(self) -> dict[str, Any]:
        return await self._tay.get_schedule(self.id)


class Scheduling:
    """Transport-neutral schedule API; transports supply a single request hook."""

    _withdrawn_schedules: set[str]

    async def _schedule_request(
        self, operation: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        raise NotImplementedError

    def _schedule_task_name(self, task: str | Task) -> str:
        return validate_task_name(task if isinstance(task, str) else task.name)

    def _retain_schedule(self, schedule_id: str, payload: dict[str, Any]) -> None:
        pass

    def _check_schedule_mode(self) -> None:
        if getattr(self, "mode", None) == "worker":
            raise ModeError(
                "worker mode only executes tasks; use embedded or client to schedule"
            )

    async def schedule(
        self,
        task: str | Task,
        *,
        cron: str,
        kwargs: Mapping[str, Any] | None = None,
        args: Mapping[str, Any] | None = None,
        declaration_id: str | None = None,
        timezone: str = "+00",
        catch_up: str = "latest",
        overlap: str | None = None,
        delay: float | None = None,
        start_at: int | None = None,
        **options: Any,
    ) -> ScheduleHandle:
        self._check_schedule_mode()
        validate_cron(cron)
        payload = self._schedule_payload(
            task,
            kwargs,
            args,
            declaration_id,
            timezone,
            catch_up,
            overlap,
            delay,
            start_at,
            options,
        )
        payload.update(cron=cron, timezone=timezone)
        return await self._declare_schedule(payload)

    async def every(
        self,
        task: str | Task,
        *,
        seconds: float | None = None,
        minutes: float | None = None,
        hours: float | None = None,
        days: float | None = None,
        kwargs: Mapping[str, Any] | None = None,
        args: Mapping[str, Any] | None = None,
        declaration_id: str | None = None,
        catch_up: str = "latest",
        overlap: str | None = None,
        delay: float | None = None,
        start_at: int | None = None,
        **options: Any,
    ) -> ScheduleHandle:
        self._check_schedule_mode()
        interval = validate_every(
            {"seconds": seconds, "minutes": minutes, "hours": hours, "days": days}
        )
        payload = self._schedule_payload(
            task,
            kwargs,
            args,
            declaration_id,
            "+00",
            catch_up,
            overlap,
            delay,
            start_at,
            options,
        )
        payload["every"] = interval
        return await self._declare_schedule(payload)

    def _schedule_payload(
        self,
        task: str | Task,
        kwargs: Mapping[str, Any] | None,
        args: Mapping[str, Any] | None,
        declaration_id: str | None,
        timezone: str,
        catch_up: str,
        overlap: str | None,
        delay: float | None,
        start_at: int | None,
        options: dict[str, Any],
    ) -> dict[str, Any]:
        if kwargs is not None and args is not None:
            raise ValidationError("pass either kwargs or args to schedule, not both")
        validate_schedule_options(
            declaration_id=declaration_id,
            timezone=timezone,
            catch_up=catch_up,
            overlap=overlap,
            delay=delay,
            start_at=start_at,
        )
        payload = {
            "task": self._schedule_task_name(task),
            "args": job_arguments(
                kwargs if kwargs is not None else args, operation="schedule"
            ),
            "catch_up": catch_up,
            "options": normalize_json(merge_enqueue_options(options, {})),
        }
        for name, value in {
            "declaration_id": declaration_id,
            "overlap": overlap,
            "delay": delay,
            "start_at": start_at,
        }.items():
            if value is not None:
                payload[name] = value
        return payload

    async def _declare_schedule(self, payload: dict[str, Any]) -> ScheduleHandle:
        reply = await self._schedule_request("schedule", payload)
        schedule_id = _extract_identifier(reply, "schedule_id", "schedule")
        self._withdrawn_schedules.discard(schedule_id)
        self._retain_schedule(schedule_id, dict(payload, declaration_id=schedule_id))
        return ScheduleHandle(schedule_id, self)

    async def _cancel_schedule(self, schedule_id: str) -> dict[str, Any]:
        identifier(schedule_id, "schedule_id")
        self._withdrawn_schedules.add(schedule_id)
        return await self._schedule_request(
            "cancel_schedule", {"schedule_id": schedule_id}
        )

    async def get_schedule(self, schedule_id: str) -> dict[str, Any]:
        identifier(schedule_id, "schedule_id")
        reply = await self._schedule_request(
            "schedule_status", {"schedule_id": schedule_id}
        )
        schedule = reply.get("schedule")
        if not isinstance(schedule, dict):
            raise ProtocolError("Tay omitted the schedule object")
        return schedule

    async def schedules(self) -> list[dict[str, Any]]:
        """Return schedules, fetching bounded pages automatically."""
        collected: list[dict[str, Any]] = []
        cursor: str | None = None
        while True:
            payload = {"cursor": cursor} if cursor is not None else {}
            reply = await self._schedule_request("schedules", payload)
            schedules = reply.get("schedules")
            if not isinstance(schedules, list) or not all(
                isinstance(item, dict) for item in schedules
            ):
                raise ProtocolError("Tay omitted the schedule list")
            collected.extend(schedules)
            next_cursor = reply.get("next_cursor")
            if next_cursor is None:
                return collected
            if (
                type(next_cursor) is not str
                or not next_cursor
                or (cursor is not None and next_cursor <= cursor)
            ):
                raise ProtocolError("Tay returned an invalid schedule cursor")
            cursor = next_cursor
