"""Task declarations and local invocation helpers."""

from __future__ import annotations

import hashlib
import inspect
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from functools import update_wrapper
from typing import TYPE_CHECKING, Any

from .errors import ValidationError
from .protocol import normalize_json, validate_task_name

if TYPE_CHECKING:  # pragma: no cover
    from .client import JobHandle, ScheduleHandle, Tay


_ENQUEUE_OPTION_NAMES = frozenset(
    {
        "delay",
        "run_at",
        "retries",
        "backoff",
        "submission_id",
        "priority",
        "queue",
        "timeout",
    }
)


@dataclass(frozen=True)
class TaskConfig:
    """Declarative metadata attached to one registered task."""

    retries: int | None = None
    backoff: str | Mapping[str, Any] | None = None
    cron: str | None = None
    every: Mapping[str, Any] | None = None
    overlap: str | None = None
    declaration_id: str | None = None

    def execution_options(self) -> dict[str, Any]:
        options: dict[str, Any] = {}
        if self.retries is not None:
            options["retries"] = self.retries
        if self.backoff is not None:
            options["backoff"] = self.backoff
        return options

    @property
    def has_schedule(self) -> bool:
        return self.cron is not None or self.every is not None


class Task:
    """A registered Python callable.

    Calling a ``Task`` runs the original Python callable locally.  Calling its
    async :meth:`enqueue` method submits a durable remote job instead.
    """

    def __init__(
        self,
        tay: Tay,
        function: Callable[..., Any],
        *,
        name: str,
        config: TaskConfig,
    ) -> None:
        self.tay = tay
        self.function = function
        self.name = validate_task_name(name)
        self.config = config
        try:
            self.signature = inspect.signature(function)
        except (TypeError, ValueError):
            self.signature = None
        update_wrapper(self, function)

    def __call__(self, *args: Any, **kwargs: Any) -> Any:
        """Run the original function locally; no socket operation occurs."""

        return self.function(*args, **kwargs)

    def __repr__(self) -> str:
        return f"Task(name={self.name!r}, function={self.function!r})"

    def _split_enqueue_kwargs(
        self, kwargs: Mapping[str, Any]
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        """Separate task keyword arguments from known submission options.

        A function parameter wins over an option of the same name.  For an
        unavoidable collision, callers can pass transport options via
        ``options={...}``.
        """

        task_keywords = dict(kwargs)
        raw_options = task_keywords.pop("options", None)
        if raw_options is None:
            options: dict[str, Any] = {}
        elif isinstance(raw_options, Mapping):
            options = dict(raw_options)
        else:
            raise ValidationError("enqueue options must be a mapping")

        parameter_names = (
            set(self.signature.parameters) if self.signature is not None else set()
        )
        for key in tuple(task_keywords):
            if key in _ENQUEUE_OPTION_NAMES and key not in parameter_names:
                options[key] = task_keywords.pop(key)
        return task_keywords, options

    def _arguments_from_call(self, args: tuple[Any, ...], kwargs: Mapping[str, Any]) -> dict[str, Any]:
        if self.signature is None:
            if args:
                raise ValidationError(
                    f"cannot serialize positional arguments for task {self.name!r}; "
                    "the callable has no inspectable signature"
                )
            return normalize_json(dict(kwargs))

        try:
            bound = self.signature.bind(*args, **kwargs)
        except TypeError as exc:
            raise ValidationError(f"invalid arguments for task {self.name!r}: {exc}") from exc
        bound.apply_defaults()

        arguments: dict[str, Any] = {}
        for parameter_name, value in bound.arguments.items():
            # ``inspect`` stores varargs as a tuple, which is deliberately not
            # a protocol value.  It has an unambiguous list representation.
            parameter = self.signature.parameters[parameter_name]
            if parameter.kind is inspect.Parameter.VAR_POSITIONAL:
                value = list(value)
            elif parameter.kind is inspect.Parameter.VAR_KEYWORD:
                value = dict(value)
            arguments[parameter_name] = value
        return normalize_json(arguments)

    def _call_from_arguments(self, arguments: Any) -> Any:
        """Invoke the wrapped function from a protocol argument object."""

        if not isinstance(arguments, Mapping):
            raise ValidationError("execution args must be a JSON object")
        if self.signature is None:
            return self.function(**dict(arguments))

        positional: list[Any] = []
        keyword: dict[str, Any] = {}
        for parameter in self.signature.parameters.values():
            if parameter.name not in arguments:
                continue
            value = arguments[parameter.name]
            if parameter.kind is inspect.Parameter.POSITIONAL_ONLY:
                positional.append(value)
            elif parameter.kind is inspect.Parameter.VAR_POSITIONAL:
                if not isinstance(value, list):
                    raise ValidationError("serialized varargs must be a list")
                positional.extend(value)
            elif parameter.kind is inspect.Parameter.VAR_KEYWORD:
                if not isinstance(value, Mapping):
                    raise ValidationError("serialized keyword varargs must be an object")
                keyword.update(value)
            else:
                keyword[parameter.name] = value
        return self.function(*positional, **keyword)

    async def enqueue(self, *args: Any, **kwargs: Any) -> JobHandle:
        """Submit a durable job using this task's stable identity."""

        task_kwargs, options = self._split_enqueue_kwargs(kwargs)
        serialized_args = self._arguments_from_call(args, task_kwargs)
        return await self.tay.enqueue(self.name, serialized_args, options=options)

    async def schedule(self, *, cron: str, kwargs: Mapping[str, Any] | None = None, **options: Any) -> ScheduleHandle:
        """Create or update a cron schedule for this task."""

        return await self.tay.schedule(self, cron=cron, kwargs=kwargs, **options)

    async def every(self, *, kwargs: Mapping[str, Any] | None = None, **units: Any) -> ScheduleHandle:
        """Create or update an interval schedule for this task."""

        return await self.tay.every(self, kwargs=kwargs, **units)

    def static_schedule_declaration(self) -> dict[str, Any] | None:
        """Return the idempotent declaration reconciled at startup, if any."""

        if not self.config.has_schedule:
            return None

        schedule: dict[str, Any] = {
            "task": self.name,
            "args": {},
            "options": self.config.execution_options(),
        }
        if self.config.cron is not None:
            schedule["cron"] = self.config.cron
        if self.config.every is not None:
            schedule["every"] = dict(self.config.every)
        if self.config.overlap is not None:
            schedule["overlap"] = self.config.overlap

        declaration_id = self.config.declaration_id
        if declaration_id is None:
            # Canonical text makes this stable across processes and Python hash
            # randomization while permitting an explicit stable override.
            import json

            fingerprint = json.dumps(schedule, sort_keys=True, separators=(",", ":"))
            digest = hashlib.sha256(fingerprint.encode("utf-8")).hexdigest()[:24]
            declaration_id = f"python:{self.name}:{digest}"
        schedule["declaration_id"] = declaration_id
        return normalize_json(schedule)
