"""Async Python client and embedded executor for Tay protocol v1."""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import os
import re
import traceback
import uuid
import weakref
from collections.abc import AsyncGenerator, Callable, Mapping
from dataclasses import dataclass
from types import TracebackType
from typing import Any, Self

from .errors import (
    ConnectionLost,
    ModeError,
    ProtocolError,
    RemoteTaskError,
    ResultTooLarge,
    ServerError,
    TaskNotRegistered,
    TaskRegistrationError,
    ValidationError,
)
from .protocol import (
    DEFAULT_MAX_FRAME_BYTES,
    PROTOCOL_VERSION,
    encode_frame,
    encoded_json_size,
    normalize_json,
    read_frame,
    validate_task_name,
)
from .socket_path import resolve_socket_path
from .task import Task, TaskConfig

DEFAULT_MAX_RESULT_BYTES = 65_536
DEFAULT_MAX_ERROR_BYTES = 8_192
_MODES = frozenset({"client", "embedded", "worker"})
# Event-v1 freezes a single durable retry curve. Keep the SDK's accepted surface
# aligned with the listener rather than accepting values it cannot represent.
_BACKOFF_MODES = frozenset({"exponential"})
_OVERLAP_POLICIES = frozenset({"allow", "skip", "queue"})
_CATCH_UP_POLICIES = frozenset({"latest", "all"})
_TIMEZONE_OFFSET = re.compile(r"^(?:UTC|Z|[+-](?:[01]\d|2[0-3])(?::[0-5]\d)?)$")


@dataclass(frozen=True)
class JobHandle:
    """A lightweight, non-authoritative reference to a durable Tay job."""

    id: str
    _tay: Tay

    async def status(self) -> Any:
        """Fetch current durable status from Tay."""

        reply = await self._tay._request("status", {"job_id": self.id})
        return reply.get("status", reply.get("job", reply))

    async def cancel(self) -> Any:
        """Request cancellation; Tay remains authoritative about the outcome."""

        reply = await self._tay._request("cancel", {"job_id": self.id})
        return reply.get("status", reply)

    async def result(self) -> Any:
        """Return bounded result data, or raise a remote failure when supplied."""

        reply = await self._tay._request("result", {"job_id": self.id})
        error = reply.get("error")
        if error:
            raise _server_error_from_payload(error)
        return reply.get("result")


@dataclass(frozen=True)
class ScheduleHandle:
    """A durable schedule reference returned by dynamic schedule APIs."""

    id: str
    _tay: Tay

    async def cancel(self) -> Any:
        reply = await self._tay._request("cancel_schedule", {"schedule_id": self.id})
        return reply.get("schedule", reply.get("status", reply))


def _server_error_from_payload(payload: Any) -> ServerError:
    if isinstance(payload, Mapping):
        message = (
            payload.get("message")
            or payload.get("reason")
            or "Tay rejected the request"
        )
        code = payload.get("code") or payload.get("type")
        if payload.get("remote_task") or code in {"task_failed", "TaskFailed"}:
            return RemoteTaskError(
                str(message), code=str(code) if code else None, details=dict(payload)
            )
        return ServerError(
            str(message), code=str(code) if code else None, details=dict(payload)
        )
    return ServerError(str(payload))


class Tay:
    """A small, stdlib-only Tay producer and executor.

    ``embedded`` (the default) both submits jobs and executes tasks registered
    with :meth:`task`.  ``client`` never accepts ``execute`` messages.  ``worker``
    advertises task capacity but deliberately cannot submit jobs.

    A client reconnects after a local Tay restart and replays only ephemeral
    registration/declaration messages.  It never automatically replays an RPC:
    a lost enqueue reply is an intentionally visible unknown outcome.
    """

    _instances: weakref.WeakSet[Tay] = weakref.WeakSet()

    def __init__(
        self,
        *,
        mode: str = "embedded",
        socket_path: str | os.PathLike[str] | None = None,
        capacity: int = 1,
        client_id: str | None = None,
        max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES,
        max_result_bytes: int = DEFAULT_MAX_RESULT_BYTES,
        max_error_bytes: int = DEFAULT_MAX_ERROR_BYTES,
        request_timeout: float = 30.0,
        connect_timeout: float = 5.0,
        reconnect_initial_delay: float = 0.05,
        reconnect_max_delay: float = 2.0,
        include_traceback: bool = True,
    ) -> None:
        if mode not in _MODES:
            raise ValidationError(f"mode must be one of {sorted(_MODES)}, not {mode!r}")
        if type(capacity) is not int or capacity not in range(1, 65_536):
            raise ValidationError("capacity must be an integer in 1..65535")
        if type(max_frame_bytes) is not int or max_frame_bytes < 256:
            raise ValidationError("max_frame_bytes must be an integer of at least 256")
        if type(max_result_bytes) is not int or max_result_bytes < 1:
            raise ValidationError("max_result_bytes must be a positive integer")
        if type(max_error_bytes) is not int or max_error_bytes < 128:
            raise ValidationError("max_error_bytes must be an integer of at least 128")
        if request_timeout <= 0 or connect_timeout <= 0:
            raise ValidationError(
                "request_timeout and connect_timeout must be positive"
            )
        if (
            reconnect_initial_delay <= 0
            or reconnect_max_delay < reconnect_initial_delay
        ):
            raise ValidationError("invalid reconnect delay configuration")

        self.mode = mode
        self.socket_path = resolve_socket_path(socket_path)
        self.capacity = capacity
        self.client_id = client_id or f"python-{uuid.uuid4().hex}"
        if (
            type(self.client_id) is not str
            or not self.client_id
            or "\x00" in self.client_id
            or len(self.client_id.encode("utf-8")) > 128
        ):
            raise ValidationError(
                "client_id must be a non-empty UTF-8 string of at most 128 bytes"
            )
        self.max_frame_bytes = max_frame_bytes
        self.max_result_bytes = max_result_bytes
        self.max_error_bytes = max_error_bytes
        self.request_timeout = float(request_timeout)
        self.connect_timeout = float(connect_timeout)
        self.reconnect_initial_delay = float(reconnect_initial_delay)
        self.reconnect_max_delay = float(reconnect_max_delay)
        self.include_traceback = bool(include_traceback)

        self._tasks: dict[str, Task] = {}
        # These are the capabilities we intend to advertise, rather than just
        # every callable that happens to be retained locally.  Keeping them
        # separate lets an executor withdraw a task without losing its Python
        # wrapper, and makes reconnect replay deterministic.
        self._registered_task_names: set[str] = set()
        self._running = False
        self._closing = False
        self._loop: asyncio.AbstractEventLoop | None = None
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._reconnect_task: asyncio.Task[None] | None = None
        self._connected = asyncio.Event()
        self._connection_lost = asyncio.Event()
        self._connection_lost.set()
        self._start_lock = asyncio.Lock()
        self._pending_lock = asyncio.Lock()
        self._write_lock = asyncio.Lock()
        self._execution_lock = asyncio.Lock()
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._event_request_ids: set[str] = set()
        self._executions: dict[str, asyncio.Task[None]] = {}
        self._execution_is_sync: dict[str, bool] = {}
        self._last_connection_error: BaseException | None = None
        Tay._instances.add(self)

    @classmethod
    def instances(cls) -> tuple[Tay, ...]:
        """Return currently live SDK instances (used by the worker CLI)."""

        return tuple(cls._instances)

    @property
    def connected(self) -> bool:
        return self._connected.is_set() and self._writer is not None

    @property
    def tasks(self) -> Mapping[str, Task]:
        """Read-only view of local task registrations."""

        return self._tasks.copy()

    def task(
        self,
        function: Callable[..., Any] | None = None,
        *,
        name: str | None = None,
        retries: int | None = None,
        backoff: str | Mapping[str, Any] | None = None,
        cron: str | None = None,
        every: Mapping[str, Any] | None = None,
        overlap: str | None = None,
        declaration_id: str | None = None,
    ) -> Task | Callable[[Callable[..., Any]], Task]:
        """Register a callable, either as ``@tay.task`` or ``@tay.task(...)``."""

        config = self._task_config(
            retries=retries,
            backoff=backoff,
            cron=cron,
            every=every,
            overlap=overlap,
            declaration_id=declaration_id,
        )

        def decorate(candidate: Callable[..., Any]) -> Task:
            if not callable(candidate):
                raise TaskRegistrationError("only callables can be registered as tasks")
            task_name = name or f"{candidate.__module__}.{candidate.__qualname__}"
            task_name = validate_task_name(task_name)
            existing = self._tasks.get(task_name)
            if existing is not None:
                if existing.function is candidate:
                    return existing
                raise TaskRegistrationError(
                    f"task name {task_name!r} is already registered to another callable"
                )
            task = Task(self, candidate, name=task_name, config=config)
            self._tasks[task_name] = task
            self._registered_task_names.add(task_name)
            return task

        if function is None:
            return decorate
        return decorate(function)

    def _task_config(self, **raw: Any) -> TaskConfig:
        retries = raw["retries"]
        if retries is not None and (type(retries) is not int or retries < 0):
            raise ValidationError("retries must be a non-negative integer")

        backoff = raw["backoff"]
        if isinstance(backoff, str):
            if backoff not in _BACKOFF_MODES:
                raise ValidationError(
                    f"backoff must be one of {sorted(_BACKOFF_MODES)}"
                )
        elif backoff is not None:
            raise ValidationError(f"backoff must be one of {sorted(_BACKOFF_MODES)}")

        cron = raw["cron"]
        every = raw["every"]
        if cron is not None and every is not None:
            raise ValidationError("a task can declare cron or every, not both")
        if cron is not None and (
            type(cron) is not str or not cron.strip() or len(cron.encode("utf-8")) > 256
        ):
            raise ValidationError(
                "cron must be a non-empty string no longer than 256 bytes"
            )
        if every is not None:
            every = self._validate_every_mapping(every)

        overlap = raw["overlap"]
        if overlap is not None and overlap not in _OVERLAP_POLICIES:
            raise ValidationError(f"overlap must be one of {sorted(_OVERLAP_POLICIES)}")

        declaration_id = raw["declaration_id"]
        if declaration_id is not None:
            if type(declaration_id) is not str or not declaration_id:
                raise ValidationError("declaration_id must be a non-empty string")
            if len(declaration_id.encode("utf-8")) > 255:
                raise ValidationError("declaration_id is too long")

        return TaskConfig(
            retries=retries,
            backoff=backoff,
            cron=cron,
            every=every,
            overlap=overlap,
            declaration_id=declaration_id,
        )

    @staticmethod
    def _validate_every_mapping(value: Mapping[str, Any]) -> dict[str, int | float]:
        if not isinstance(value, Mapping):
            raise ValidationError("every must be a mapping such as {'minutes': 4}")
        allowed = {"seconds", "minutes", "hours", "days"}
        if set(value) - allowed:
            raise ValidationError("every only accepts seconds, minutes, hours, or days")
        present = [(key, item) for key, item in value.items() if item is not None]
        if len(present) != 1:
            raise ValidationError("every requires exactly one positive time unit")
        unit, amount = present[0]
        if type(amount) not in {int, float} or amount <= 0:
            raise ValidationError(f"every.{unit} must be a positive finite number")
        if type(amount) is float and not float(amount) < float("inf"):
            raise ValidationError(f"every.{unit} must be finite")
        return {unit: amount}

    async def __aenter__(self) -> Self:
        await self.start()
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback_: TracebackType | None,
    ) -> None:
        await self.close()

    def lifespan(self) -> Callable[[Any], contextlib.AbstractAsyncContextManager[None]]:
        """Return a FastAPI-compatible lifespan callable without importing FastAPI."""

        @contextlib.asynccontextmanager
        async def _lifespan(_app: Any) -> AsyncGenerator[None, None]:
            async with self:
                yield

        return _lifespan

    async def start(self) -> Tay:
        """Start connection management and wait for the first successful handshake."""

        self._ensure_event_loop()
        async with self._start_lock:
            if not self._running:
                self._running = True
                self._closing = False
                self._reconnect_task = asyncio.create_task(
                    self._connection_supervisor(), name="tay-reconnect"
                )
        await self._wait_until_connected()
        return self

    async def close(self) -> None:
        """Stop reconnecting, close the socket, and release pending callers."""

        if self._loop is not None:
            self._ensure_event_loop()
        async with self._start_lock:
            self._running = False
            self._closing = True
            reconnect_task = self._reconnect_task
            self._reconnect_task = None
            reader_task = self._reader_task
            writer = self._writer
            self._connected.clear()
            self._connection_lost.set()

        if reconnect_task is not None:
            reconnect_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await reconnect_task
        if reader_task is not None and reader_task is not asyncio.current_task():
            reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await reader_task
        await self._fail_pending(ConnectionLost("Tay client was closed"))

        # Async functions are cooperatively cancelled.  A running synchronous
        # function may continue in its worker thread; Python offers no safe hard
        # cancellation for it, so its eventual outcome is intentionally ignored.
        for execution in tuple(self._executions.values()):
            execution.cancel()
        self._executions.clear()
        self._execution_is_sync.clear()
        self._event_request_ids.clear()
        await self._close_writer(writer)
        self._reader = None
        self._writer = None
        self._reader_task = None

    def _ensure_event_loop(self) -> None:
        loop = asyncio.get_running_loop()
        if self._loop is None:
            self._loop = loop
        elif self._loop is not loop:
            raise RuntimeError(
                "a Tay instance must be used from one asyncio event loop"
            )

    async def _wait_until_connected(self) -> None:
        if self.connected:
            return
        try:
            await asyncio.wait_for(self._connected.wait(), timeout=self.connect_timeout)
        except TimeoutError as exc:
            detail = (
                f": {self._last_connection_error}"
                if self._last_connection_error
                else ""
            )
            raise ConnectionLost(
                f"could not connect to Tay at {self.socket_path!r} within "
                f"{self.connect_timeout:g}s{detail}"
            ) from exc

    async def _connection_supervisor(self) -> None:
        delay = self.reconnect_initial_delay
        while self._running:
            writer: asyncio.StreamWriter | None = None
            try:
                self._connection_lost.clear()
                reader, writer = await asyncio.open_unix_connection(self.socket_path)
                if not self._running:
                    await self._close_writer(writer)
                    return
                self._reader = reader
                self._writer = writer
                self._reader_task = asyncio.create_task(
                    self._read_loop(reader, writer), name="tay-reader"
                )
                await self._bootstrap()
                self._connected.set()
                delay = self.reconnect_initial_delay
                await self._connection_lost.wait()
            except asyncio.CancelledError:
                return
            except Exception as exc:  # noqa: BLE001 - reconnect supervision boundary
                self._last_connection_error = exc
                self._connected.clear()
            finally:
                self._connected.clear()
                await self._detach_connection(writer)

            if self._running:
                await asyncio.sleep(delay)
                delay = min(delay * 2, self.reconnect_max_delay)

    async def _detach_connection(self, writer: asyncio.StreamWriter | None) -> None:
        if writer is None:
            return
        reader_task = self._reader_task
        if self._writer is writer:
            self._writer = None
            self._reader = None
            self._reader_task = None
        if reader_task is not None and reader_task is not asyncio.current_task():
            reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await reader_task
        await self._close_writer(writer)

    @staticmethod
    async def _close_writer(writer: asyncio.StreamWriter | None) -> None:
        if writer is None:
            return
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()

    async def _bootstrap(self) -> None:
        await self._exchange(
            "hello",
            {
                "mode": self.mode,
                "runtime_id": self.client_id,
                "max_concurrency": self.capacity if self.mode != "client" else 0,
            },
        )
        if self.mode != "client" and self._registered_task_names:
            await self._exchange(
                "register_tasks", {"tasks": sorted(self._registered_task_names)}
            )

    async def _read_loop(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            while self._running and self._writer is writer:
                message = await read_frame(reader, max_frame_bytes=self.max_frame_bytes)
                await self._handle_message(message)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            self._last_connection_error = exc
        finally:
            if self._writer is writer:
                self._event_request_ids.clear()
                self._connected.clear()
                self._connection_lost.set()
                await self._fail_pending(ConnectionLost("connection to Tay was lost"))

    async def _handle_message(self, message: dict[str, Any]) -> None:
        message_type = message["type"]
        if message_type == "execute":
            await self._accept_execution(message)
            return
        if message_type == "cancel_execution":
            await self._cancel_execution(message)
            return
        if message_type == "ping":
            await self._send_event("pong", {"ping_id": message.get("ping_id")})
            return

        request_id = message.get("request_id")
        if request_id is not None:
            if (
                message_type in {"accepted", "heartbeat_ok"}
                and request_id in self._event_request_ids
            ):
                self._event_request_ids.discard(request_id)
                return
            future = self._pending.pop(request_id, None)
            if future is not None and not future.done():
                if message_type in {"error", "protocol_error"}:
                    future.set_exception(
                        _server_error_from_payload(message.get("error", message))
                    )
                else:
                    future.set_result(message)
                return
        # A server should not emit arbitrary unsolicited messages.  Treat one as
        # a protocol violation instead of retaining unbounded unknown state.
        raise ProtocolError(f"unexpected protocol message type {message_type!r}")

    async def _fail_pending(self, error: BaseException) -> None:
        async with self._pending_lock:
            pending = tuple(self._pending.values())
            self._pending.clear()
        for future in pending:
            if not future.done():
                future.set_exception(error)

    async def _send_envelope(self, envelope: Mapping[str, Any]) -> None:
        writer = self._writer
        if writer is None or writer.is_closing():
            raise ConnectionLost("Tay socket is not connected")
        frame = encode_frame(envelope, max_frame_bytes=self.max_frame_bytes)
        async with self._write_lock:
            if self._writer is not writer or writer.is_closing():
                raise ConnectionLost(
                    "Tay socket disconnected before request could be sent"
                )
            try:
                writer.write(frame)
                await writer.drain()
            except (ConnectionError, OSError) as exc:
                self._connection_lost.set()
                raise ConnectionLost("failed to write to Tay") from exc

    async def _send_event(self, message_type: str, fields: Mapping[str, Any]) -> None:
        request_id = uuid.uuid4().hex
        envelope = {
            "version": PROTOCOL_VERSION,
            "type": message_type,
            "request_id": request_id,
            **normalize_json(fields),
        }
        self._event_request_ids.add(request_id)
        try:
            await self._send_envelope(envelope)
        except Exception:
            self._event_request_ids.discard(request_id)
            raise

    async def _exchange(
        self, message_type: str, fields: Mapping[str, Any]
    ) -> dict[str, Any]:
        """Issue exactly one request without retrying it after a disconnect."""

        request_id = uuid.uuid4().hex
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        envelope = {
            "version": PROTOCOL_VERSION,
            "type": message_type,
            "request_id": request_id,
            **normalize_json(fields),
        }
        async with self._pending_lock:
            if self._writer is None:
                raise ConnectionLost("Tay socket is not connected")
            self._pending[request_id] = future
        try:
            await self._send_envelope(envelope)
        except Exception:
            async with self._pending_lock:
                self._pending.pop(request_id, None)
            if not future.done():
                future.cancel()
            raise
        try:
            return await asyncio.wait_for(
                asyncio.shield(future), timeout=self.request_timeout
            )
        except TimeoutError as exc:
            raise ConnectionLost(
                f"Tay did not reply to {message_type!r} within {self.request_timeout:g}s"
            ) from exc
        finally:
            async with self._pending_lock:
                self._pending.pop(request_id, None)

    async def _request(
        self, message_type: str, fields: Mapping[str, Any]
    ) -> dict[str, Any]:
        await self.start()
        return await self._exchange(message_type, fields)

    def _task_name(self, task: str | Task) -> str:
        if isinstance(task, Task):
            if task.tay is not self:
                raise ValidationError(
                    "a Task can only be used with the Tay instance that created it"
                )
            return task.name
        return validate_task_name(task)

    def _registered_task_name(self, task: str | Task) -> str:
        name = self._task_name(task)
        if self._tasks.get(name) is None:
            raise TaskRegistrationError(
                f"task {name!r} is not registered on this Tay instance"
            )
        return name

    async def register_tasks(self, *tasks: str | Task) -> tuple[Task, ...]:
        """Advertise locally registered tasks to a running executor.

        Tasks declared before :meth:`start` are registered during the initial
        handshake.  Use this method after declaring tasks at runtime; the
        desired registrations are also replayed after a reconnect.
        """

        if self.mode == "client":
            raise ModeError("client mode cannot register execution tasks")
        if not tasks:
            return ()
        names = tuple(dict.fromkeys(self._registered_task_name(task) for task in tasks))
        self._registered_task_names.update(names)
        await self._request("register_tasks", {"tasks": list(names)})
        return tuple(self._tasks[name] for name in names)

    async def unregister_tasks(self, *tasks: str | Task) -> tuple[str, ...]:
        """Withdraw task capabilities without discarding their local wrappers.

        The withdrawal is remembered across reconnects.  Running executions
        remain fenced by Tay and may still settle according to the server's
        cancellation semantics.
        """

        if self.mode == "client":
            raise ModeError("client mode cannot unregister execution tasks")
        if not tasks:
            return ()
        names = tuple(dict.fromkeys(self._registered_task_name(task) for task in tasks))
        self._registered_task_names.difference_update(names)
        # Keep the desired state withdrawn even when this RPC has an unknown
        # transport outcome. Registrations are connection-scoped, and a later
        # bootstrap must not accidentally resurrect the capability.
        await self._request("unregister_tasks", {"tasks": list(names)})
        return names

    async def enqueue(
        self,
        task: str | Task,
        args: Mapping[str, Any] | None = None,
        *,
        options: Mapping[str, Any] | None = None,
        **option_keywords: Any,
    ) -> JobHandle:
        """Submit a named task with a JSON-object argument map.

        ``submission_id`` in ``options`` makes a caller-managed retry of an
        unknown enqueue outcome idempotent when the server supports it.
        """

        if self.mode == "worker":
            raise ModeError(
                "worker mode only executes tasks; use embedded or client to enqueue"
            )
        task_name = self._task_name(task)
        if args is None:
            args = {}
        if not isinstance(args, Mapping):
            raise ValidationError("enqueue args must be a JSON object")
        merged_options = dict(options or {})
        if not isinstance(options or {}, Mapping):
            raise ValidationError("enqueue options must be a mapping")
        overlap = set(merged_options).intersection(option_keywords)
        if overlap:
            raise ValidationError(f"enqueue option supplied twice: {min(overlap)}")
        merged_options.update(option_keywords)
        backoff = merged_options.get("backoff")
        if not (backoff is None or backoff == "exponential"):
            raise ValidationError("Protocol v1 supports only backoff='exponential'")
        payload = {
            "task": task_name,
            "args": normalize_json(args),
            "options": normalize_json(merged_options),
        }
        reply = await self._request("enqueue", payload)
        job_id = _extract_identifier(reply, "job_id", "job")
        return JobHandle(job_id, self)

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
        """Create or reconcile a cron schedule for a task."""

        if self.mode == "worker":
            raise ModeError(
                "worker mode only executes tasks; use embedded or client to schedule"
            )
        if kwargs is not None and args is not None:
            raise ValidationError("pass either kwargs or args to schedule, not both")
        if type(cron) is not str or not cron.strip() or len(cron.encode("utf-8")) > 256:
            raise ValidationError(
                "cron must be a non-empty string no longer than 256 bytes"
            )
        self._validate_schedule_options(
            declaration_id=declaration_id,
            timezone=timezone,
            catch_up=catch_up,
            overlap=overlap,
            delay=delay,
            start_at=start_at,
        )
        payload: dict[str, Any] = {
            "task": self._task_name(task),
            "args": normalize_json(kwargs if kwargs is not None else args or {}),
            "cron": cron,
            "timezone": timezone,
            "catch_up": catch_up,
            "options": normalize_json(options),
        }
        if declaration_id is not None:
            payload["declaration_id"] = declaration_id
        if overlap is not None:
            payload["overlap"] = overlap
        if delay is not None:
            payload["delay"] = delay
        if start_at is not None:
            payload["start_at"] = start_at
        reply = await self._request("schedule", payload)
        return ScheduleHandle(
            _extract_identifier(reply, "schedule_id", "schedule"), self
        )

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
        """Create or reconcile an interval schedule using exactly one unit."""

        every = self._validate_every_mapping(
            {
                "seconds": seconds,
                "minutes": minutes,
                "hours": hours,
                "days": days,
            }
        )
        if self.mode == "worker":
            raise ModeError(
                "worker mode only executes tasks; use embedded or client to schedule"
            )
        if kwargs is not None and args is not None:
            raise ValidationError("pass either kwargs or args to every, not both")
        self._validate_schedule_options(
            declaration_id=declaration_id,
            timezone="+00",
            catch_up=catch_up,
            overlap=overlap,
            delay=delay,
            start_at=start_at,
        )
        payload: dict[str, Any] = {
            "task": self._task_name(task),
            "args": normalize_json(kwargs if kwargs is not None else args or {}),
            "every": every,
            "catch_up": catch_up,
            "options": normalize_json(options),
        }
        if declaration_id is not None:
            payload["declaration_id"] = declaration_id
        if overlap is not None:
            payload["overlap"] = overlap
        if delay is not None:
            payload["delay"] = delay
        if start_at is not None:
            payload["start_at"] = start_at
        reply = await self._request("schedule", payload)
        return ScheduleHandle(
            _extract_identifier(reply, "schedule_id", "schedule"), self
        )

    @staticmethod
    def _validate_schedule_options(
        *,
        declaration_id: str | None,
        timezone: str,
        catch_up: str,
        overlap: str | None,
        delay: float | None,
        start_at: int | None,
    ) -> None:
        if declaration_id is not None and (
            type(declaration_id) is not str or not declaration_id
        ):
            raise ValidationError("declaration_id must be a non-empty string")
        if type(timezone) is not str or not _TIMEZONE_OFFSET.fullmatch(timezone):
            raise ValidationError(
                "timezone must be UTC, Z, or an offset such as +01 or -02:30"
            )
        if catch_up not in _CATCH_UP_POLICIES:
            raise ValidationError(
                f"catch_up must be one of {sorted(_CATCH_UP_POLICIES)}"
            )
        if overlap is not None and overlap not in _OVERLAP_POLICIES:
            raise ValidationError(f"overlap must be one of {sorted(_OVERLAP_POLICIES)}")
        if delay is not None and (
            type(delay) not in {int, float}
            or delay < 0
            or (type(delay) is float and not float(delay) < float("inf"))
        ):
            raise ValidationError(
                "delay must be a finite non-negative number of seconds"
            )
        if start_at is not None and (type(start_at) is not int or start_at < 0):
            raise ValidationError(
                "start_at must be a non-negative UTC millisecond timestamp"
            )
        if delay is not None and start_at is not None:
            raise ValidationError("pass either delay or start_at, not both")

    async def _accept_execution(self, message: Mapping[str, Any]) -> None:
        if self.mode == "client":
            await self._execution_failure(
                message,
                TaskNotRegistered("client mode does not execute tasks"),
            )
            return
        execution_id = message.get("execution_id")
        reservation_id = message.get("reservation_id")
        job_id = message.get("job_id")
        task_name = message.get("task", message.get("task_name"))
        arguments = message.get("args", {})
        if type(execution_id) is not str or not execution_id:
            raise ProtocolError("execute requires a non-empty execution_id")
        if type(reservation_id) is not str or not reservation_id:
            raise ProtocolError("execute requires a non-empty reservation_id")
        if type(job_id) is not str or not job_id:
            raise ProtocolError("execute requires a non-empty job_id")
        if type(task_name) is not str:
            raise ProtocolError("execute requires a string task")
        if not isinstance(arguments, Mapping):
            await self._execution_failure(
                message, ValidationError("execute args must be a JSON object")
            )
            return
        task = self._tasks.get(task_name)
        if task is None:
            await self._execution_failure(
                message, TaskNotRegistered(f"task {task_name!r} is not registered")
            )
            return

        async with self._execution_lock:
            existing = self._executions.get(execution_id)
            if existing is not None:
                # Duplicate delivery of an active execution must not start a
                # second local invocation.  Reaffirming STARTED is harmless.
                await self._send_event(
                    "started",
                    {"reservation_id": reservation_id, "execution_id": execution_id},
                )
                return
            if len(self._executions) >= self.capacity:
                await self._execution_failure(
                    message,
                    ServerError("executor capacity exceeded", code="over_capacity"),
                )
                return
            synchronous = not inspect.iscoroutinefunction(task.function)
            execution = asyncio.create_task(
                self._run_execution(
                    reservation_id,
                    execution_id,
                    job_id,
                    task,
                    dict(arguments),
                    synchronous,
                ),
                name=f"tay-execution-{execution_id}",
            )
            self._executions[execution_id] = execution
            self._execution_is_sync[execution_id] = synchronous
            execution.add_done_callback(
                lambda _done, key=execution_id: self._execution_finished(key)
            )

    def _execution_finished(self, execution_id: str) -> None:
        self._executions.pop(execution_id, None)
        self._execution_is_sync.pop(execution_id, None)

    async def _cancel_execution(self, message: Mapping[str, Any]) -> None:
        execution_id = message.get("execution_id")
        if type(execution_id) is not str or not execution_id:
            raise ProtocolError("cancel_execution requires a non-empty execution_id")
        execution = self._executions.get(execution_id)
        # Safely interrupt async work.  A synchronous function runs in a thread
        # and cannot be safely killed by Python; leave it running and let Tay's
        # durable cancellation fence decide whether its eventual outcome counts.
        if execution is not None and not self._execution_is_sync.get(
            execution_id, False
        ):
            execution.cancel()

    async def _run_execution(
        self,
        reservation_id: str,
        execution_id: str,
        job_id: str,
        task: Task,
        arguments: Mapping[str, Any],
        synchronous: bool,
    ) -> None:
        await self._send_event(
            "started",
            {
                "reservation_id": reservation_id,
                "execution_id": execution_id,
                "job_id": job_id,
            },
        )
        try:
            if synchronous:
                result = await asyncio.to_thread(task._call_from_arguments, arguments)
            else:
                result = task._call_from_arguments(arguments)
                if inspect.isawaitable(result):
                    result = await result
            # A callable that was not declared async may still deliberately
            # return an awaitable; support that convention without making it
            # the common path.
            if inspect.isawaitable(result):
                result = await result
            result = normalize_json(result)
            result_size = encoded_json_size(result)
            if result_size > self.max_result_bytes:
                raise ResultTooLarge(
                    f"task result is {result_size} bytes; limit is {self.max_result_bytes} bytes"
                )
            await self._send_event(
                "succeeded",
                {
                    "reservation_id": reservation_id,
                    "execution_id": execution_id,
                    "job_id": job_id,
                    "result": result,
                },
            )
        except asyncio.CancelledError:
            with contextlib.suppress(ConnectionLost, OSError):
                await self._send_event(
                    "failed",
                    {
                        "reservation_id": reservation_id,
                        "execution_id": execution_id,
                        "job_id": job_id,
                        "error": {
                            "type": "CancelledError",
                            "message": "async execution cancelled cooperatively",
                            "cancelled": True,
                        },
                    },
                )
            raise
        except Exception as exc:  # noqa: BLE001 - user task exceptions must become FAILED
            with contextlib.suppress(ConnectionLost, OSError):
                await self._send_event(
                    "failed",
                    {
                        "reservation_id": reservation_id,
                        "execution_id": execution_id,
                        "job_id": job_id,
                        "error": self._bounded_error(exc),
                    },
                )

    async def _execution_failure(
        self, message: Mapping[str, Any], error: BaseException
    ) -> None:
        execution_id = message.get("execution_id")
        reservation_id = message.get("reservation_id")
        if (
            type(execution_id) is not str
            or not execution_id
            or type(reservation_id) is not str
            or not reservation_id
        ):
            raise ProtocolError(
                "cannot report execute failure without execution context"
            )
        fields: dict[str, Any] = {
            "reservation_id": reservation_id,
            "execution_id": execution_id,
            "error": self._bounded_error(error),
        }
        if isinstance(message.get("job_id"), str):
            fields["job_id"] = message["job_id"]
        with contextlib.suppress(ConnectionLost, OSError):
            await self._send_event("failed", fields)

    def _bounded_error(self, exc: BaseException) -> dict[str, Any]:
        error: dict[str, Any] = {
            "type": type(exc).__name__,
            "message": str(exc) or type(exc).__name__,
        }
        if self.include_traceback:
            error["traceback"] = "".join(
                traceback.format_exception(type(exc), exc, exc.__traceback__)
            )
        # Trim text fields until the JSON representation obeys the configured
        # cap.  This never silently truncates a successful result.
        while encoded_json_size(error) > self.max_error_bytes:
            if error.get("traceback"):
                error["traceback"] = _truncate_text(str(error["traceback"]))
            elif error.get("message"):
                error["message"] = _truncate_text(str(error["message"]))
            else:  # defensive fallback for tiny custom limits
                return {
                    "type": type(exc).__name__,
                    "message": "error metadata exceeded limit",
                }
        return normalize_json(error)


def _truncate_text(value: str) -> str:
    if len(value) <= 1:
        return ""
    return value[: max(1, len(value) // 2 - 1)] + "…"


def _extract_identifier(reply: Mapping[str, Any], field: str, nested_field: str) -> str:
    identifier = reply.get(field)
    if identifier is None:
        nested = reply.get(nested_field)
        if isinstance(nested, Mapping):
            identifier = nested.get("id")
    if type(identifier) is not str or not identifier:
        raise ProtocolError(f"Tay reply did not include a valid {field}")
    return identifier
