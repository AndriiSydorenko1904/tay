"""Async Python client and embedded executor for Tay protocol v1."""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import os
import uuid
import weakref
from collections.abc import AsyncGenerator, Callable, Mapping
from dataclasses import dataclass
from types import TracebackType
from typing import Any, ClassVar, Self

from .errors import (
    ConnectionLost,
    ModeError,
    ProtocolError,
    ServerError,
    TaskNotRegistered,
    TaskRegistrationError,
    ValidationError,
)
from .execution import bounded_error, cancel_async_execution, run_task
from .job_options import enqueue_payload
from .protocol import (
    DEFAULT_MAX_FRAME_BYTES,
    validate_task_name,
)
from .responses import (
    _extract_identifier,
    _extract_job_durability,
    extract_result,
)
from .results import wait_result
from .schedules import ScheduleHandle, Scheduling, validate_every
from .socket_connection import SocketConnection
from .socket_path import resolve_socket_path
from .task import Durability, Task, TaskConfig, register_task
from .validation import identifier, positive_finite

__all__ = ["JobHandle", "ScheduleHandle", "Tay"]

DEFAULT_MAX_RESULT_BYTES = 65_536
DEFAULT_MAX_ERROR_BYTES = 8_192
_MODES = frozenset({"client", "embedded", "worker"})
# Event-v1 freezes a single durable retry curve. Keep the SDK's accepted surface
# aligned with the listener rather than accepting values it cannot represent.


@dataclass(frozen=True)
class JobHandle:
    """A lightweight, non-authoritative reference to a Tay job."""

    id: str
    _tay: Tay
    durability: Durability | None = None

    async def status(self) -> Any:
        """Fetch the job's current status from Tay."""

        reply = await self._tay._request("status", {"job_id": self.id})
        return reply.get("status", reply.get("job", reply))

    async def cancel(self) -> Any:
        """Request cancellation; Tay remains authoritative about the outcome."""

        reply = await self._tay._request("cancel", {"job_id": self.id})
        return reply.get("status", reply)

    async def result(self) -> Any:
        """Return bounded result data, or raise a remote failure when supplied."""

        reply = await self._tay._request("result", {"job_id": self.id})
        return extract_result(reply)

    async def wait_result(
        self, *, timeout: float = 30.0, poll_interval: float = 0.1
    ) -> Any:
        """Wait up to timeout seconds; propagate terminal errors without resubmission."""
        return await wait_result(self, timeout=timeout, poll_interval=poll_interval)


class Tay(Scheduling):
    """A small, stdlib-only Tay producer and executor.

    ``embedded`` (the default) both submits jobs and executes tasks registered
    with :meth:`task`.  ``client`` never accepts ``execute`` messages.  ``worker``
    advertises task capacity but deliberately cannot submit jobs.

    A client reconnects after a local Tay restart and reconciles its task
    registrations and desired durable schedules. It never automatically replays a request:
    a lost enqueue reply is an intentionally visible unknown outcome.
    """

    _instances: ClassVar[weakref.WeakSet[Tay]] = weakref.WeakSet()

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
        if not isinstance(mode, str) or mode not in _MODES:
            raise ValidationError(f"mode must be one of {sorted(_MODES)}, not {mode!r}")
        if type(capacity) is not int or capacity not in range(1, 65_536):
            raise ValidationError("capacity must be an integer in 1..65535")
        if type(max_frame_bytes) is not int or max_frame_bytes < 256:
            raise ValidationError("max_frame_bytes must be an integer of at least 256")
        if type(max_result_bytes) is not int or max_result_bytes < 1:
            raise ValidationError("max_result_bytes must be a positive integer")
        if type(max_error_bytes) is not int or max_error_bytes < 128:
            raise ValidationError("max_error_bytes must be an integer of at least 128")
        request_timeout = positive_finite(request_timeout, "request_timeout")
        connect_timeout = positive_finite(connect_timeout, "connect_timeout")
        reconnect_initial_delay = positive_finite(
            reconnect_initial_delay, "reconnect_initial_delay"
        )
        reconnect_max_delay = positive_finite(
            reconnect_max_delay, "reconnect_max_delay"
        )
        if reconnect_max_delay < reconnect_initial_delay:
            raise ValidationError("invalid reconnect delay configuration")

        self.mode = mode
        self.socket_path = resolve_socket_path(socket_path)
        self.capacity = capacity
        self.client_id = identifier(
            f"python-{uuid.uuid4().hex}" if client_id is None else client_id,
            "client_id",
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
        # Keep desired durable declarations client-side so reconnect can
        # reconcile startup schedules before advertising the connection as ready.
        self._schedule_declarations: dict[str, dict[str, Any]] = {}
        self._withdrawn_schedules: set[str] = set()
        self._execution_lock = asyncio.Lock()
        self._executions: dict[str, asyncio.Task[None]] = {}
        self._execution_is_sync: dict[str, bool] = {}
        self._execution_connections: dict[str, asyncio.StreamWriter | None] = {}
        self._connection = SocketConnection(
            self,
            bootstrap=self._bootstrap,
            on_execution=self._handle_execution_message,
            on_disconnect=self._connection_detached,
        )
        Tay._instances.add(self)

    @classmethod
    def instances(cls) -> tuple[Tay, ...]:
        """Return currently live SDK instances (used by the worker CLI)."""

        return tuple(cls._instances)

    @property
    def connected(self) -> bool:
        return self._connection.connected

    @property
    def tasks(self) -> Mapping[str, Task]:
        """Read-only view of local task registrations."""

        return self._tasks.copy()

    def task(
        self,
        function: Callable[..., Any] | None = None,
        *,
        name: str | None = None,
        retries: int | str | None = None,
        backoff: str | Mapping[str, Any] | None = None,
        durability: Durability | None = None,
        availability_key: str | None = None,
        cron: str | None = None,
        every: Mapping[str, Any] | None = None,
        overlap: str | None = None,
        declaration_id: str | None = None,
    ) -> Task | Callable[[Callable[..., Any]], Task]:
        """Register a callable, either as ``@tay.task`` or ``@tay.task(...)``."""

        config = self._task_config(
            retries=retries,
            backoff=backoff,
            durability=durability,
            availability_key=availability_key,
            cron=cron,
            every=every,
            overlap=overlap,
            declaration_id=declaration_id,
        )

        def decorate(candidate: Callable[..., Any]) -> Task:
            task = register_task(self, self._tasks, candidate, name=name, config=config)
            task_name = task.name
            self._registered_task_names.add(task_name)
            return task

        if function is None:
            return decorate
        return decorate(function)

    def _task_config(self, **raw: Any) -> TaskConfig:
        every = raw["every"]
        return TaskConfig(
            **{**raw, "every": validate_every(every) if every is not None else None}
        )

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
        await self._connection.start()
        return self

    async def close(self) -> None:
        """Stop reconnecting, close the socket, and release pending callers."""
        await self._connection.close()
        # Async functions are cooperatively cancelled. A running synchronous
        # function may continue in its worker thread; its outcome is ignored.
        for execution in tuple(self._executions.values()):
            execution.cancel()
        self._executions.clear()
        self._execution_is_sync.clear()
        self._execution_connections.clear()

    def _connection_detached(self, writer: asyncio.StreamWriter) -> None:
        for key, connection in tuple(self._execution_connections.items()):
            if connection is writer:
                cancel_async_execution(
                    self._executions.get(key), self._execution_is_sync.get(key, False)
                )

    async def _bootstrap(self) -> None:
        await self._connection.exchange(
            "hello",
            {
                "mode": self.mode,
                "runtime_id": self.client_id,
                "max_concurrency": self.capacity if self.mode != "client" else 0,
            },
        )
        declarations = dict(self._schedule_declarations)
        for task in self._tasks.values():
            declaration = task.static_schedule_declaration()
            if (
                declaration is not None
                and declaration["declaration_id"] not in self._withdrawn_schedules
            ):
                declarations[declaration["declaration_id"]] = declaration
        for declaration_id in sorted(declarations):
            await self._connection.exchange("schedule", declarations[declaration_id])
        # Advertise execution capacity only after the control-plane state is
        # restored. Otherwise a large recovered backlog can begin dispatching
        # and starve schedule reconciliation on the shared socket.
        if self.mode != "client" and self._registered_task_names:
            await self._connection.exchange(
                "register_tasks", {"tasks": sorted(self._registered_task_names)}
            )

    async def _handle_execution_message(self, message: dict[str, Any]) -> None:
        if message["type"] == "execute":
            await self._accept_execution(message)
        else:
            await self._cancel_execution(message)

    async def _request(
        self, message_type: str, fields: Mapping[str, Any]
    ) -> dict[str, Any]:
        await self.start()
        return await self._connection.exchange(message_type, fields)

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
        # Keep the desired state withdrawn even when this request has an unknown
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
        durability: Durability | None = None,
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
        payload = enqueue_payload(task_name, args, options, option_keywords, durability)
        reply = await self._request("enqueue", payload)
        job_id = _extract_identifier(reply, "job_id", "job")
        return JobHandle(job_id, self, _extract_job_durability(reply))

    async def _schedule_request(
        self, operation: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        return await self._request(operation, payload)

    def _schedule_task_name(self, task: str | Task) -> str:
        return self._task_name(task)

    def _retain_schedule(self, schedule_id: str, payload: dict[str, Any]) -> None:
        self._schedule_declarations[schedule_id] = payload

    async def _cancel_schedule(self, schedule_id: str) -> dict[str, Any]:
        identifier(schedule_id, "schedule_id")
        self._schedule_declarations.pop(schedule_id, None)
        return await super()._cancel_schedule(schedule_id)

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
                await self._connection.send_event(
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
                    connection=self._connection.writer,
                ),
                name=f"tay-execution-{execution_id}",
            )
            self._executions[execution_id] = execution
            self._execution_is_sync[execution_id] = synchronous
            self._execution_connections[execution_id] = self._connection.writer

            def finished(done: asyncio.Task[None]) -> None:
                self._execution_finished(execution_id)
                if not done.cancelled() and (error := done.exception()) is not None:
                    asyncio.get_running_loop().call_exception_handler(
                        {
                            "message": "Tay socket worker could not settle execution",
                            "exception": error,
                        }
                    )

            execution.add_done_callback(finished)

    def _execution_finished(self, execution_id: str) -> None:
        self._executions.pop(execution_id, None)
        self._execution_is_sync.pop(execution_id, None)
        self._execution_connections.pop(execution_id, None)

    async def _cancel_execution(self, message: Mapping[str, Any]) -> None:
        execution_id = message.get("execution_id")
        if type(execution_id) is not str or not execution_id:
            raise ProtocolError("cancel_execution requires a non-empty execution_id")
        execution = self._executions.get(execution_id)
        # Safely interrupt async work.  A synchronous function runs in a thread
        # and cannot be safely killed by Python; leave it running and let Tay's
        # durable cancellation fence decide whether its eventual outcome counts.
        cancel_async_execution(
            execution, self._execution_is_sync.get(execution_id, False)
        )

    async def _run_execution(
        self,
        reservation_id: str,
        execution_id: str,
        job_id: str,
        task: Task,
        arguments: Mapping[str, Any],
        synchronous: bool,
        *,
        connection: asyncio.StreamWriter | None = None,
    ) -> None:
        async def send_event(kind: str, fields: Mapping[str, Any]) -> None:
            if connection is not None and self._connection.writer is not connection:
                return
            if connection is None:
                await self._connection.send_event(kind, fields)
            else:
                await self._connection.send_event(kind, fields, connection=connection)

        def awaitable_started() -> None:
            self._execution_is_sync[execution_id] = False
            if connection is not None and self._connection.writer is not connection:
                raise asyncio.CancelledError

        if connection is not None and self._connection.writer is not connection:
            return
        await send_event(
            "started",
            {
                "reservation_id": reservation_id,
                "execution_id": execution_id,
                "job_id": job_id,
            },
        )
        if connection is not None and self._connection.writer is not connection:
            return
        try:
            result = await run_task(
                task,
                arguments,
                synchronous=synchronous,
                max_result_bytes=self.max_result_bytes,
                on_awaitable=awaitable_started,
            )
        except asyncio.CancelledError:
            with contextlib.suppress(ConnectionLost, OSError):
                await send_event(
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
                await send_event(
                    "failed",
                    {
                        "reservation_id": reservation_id,
                        "execution_id": execution_id,
                        "job_id": job_id,
                        "error": self._bounded_error(exc),
                    },
                )
        else:
            await send_event(
                "succeeded",
                {
                    "reservation_id": reservation_id,
                    "execution_id": execution_id,
                    "job_id": job_id,
                    "result": result,
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
            await self._connection.send_event("failed", fields)

    def _bounded_error(self, exc: BaseException) -> dict[str, Any]:
        return bounded_error(
            exc,
            max_bytes=self.max_error_bytes,
            include_traceback=self.include_traceback,
        )
