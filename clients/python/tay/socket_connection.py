"""Internal Unix-socket lifecycle and request/reply transport for the Python SDK.

The connection owns framing, response correlation, timeouts and reconnects.
The client supplies handshake reconciliation and execution callbacks; the
transport never registers or runs user tasks and never replays a request.
"""

from __future__ import annotations

import asyncio
import contextlib
import uuid
from collections.abc import Awaitable, Callable, Mapping
from typing import Any, Protocol

from .errors import ConnectionLost, ProtocolError
from .protocol import PROTOCOL_VERSION, encode_frame, normalize_json, read_frame
from .responses import _server_error_from_payload


class SocketConfig(Protocol):
    """Read current transport settings without depending on the client class."""

    socket_path: str
    max_frame_bytes: int
    request_timeout: float
    connect_timeout: float
    reconnect_initial_delay: float
    reconnect_max_delay: float


class SocketConnection:
    """One reconnecting socket with connection-scoped pending responses."""

    def __init__(
        self,
        config: SocketConfig,
        *,
        bootstrap: Callable[[], Awaitable[None]],
        on_execution: Callable[[dict[str, Any]], Awaitable[None]],
        on_disconnect: Callable[[asyncio.StreamWriter], None],
    ) -> None:
        self._config = config
        self._bootstrap = bootstrap
        self._on_execution = on_execution
        self._on_disconnect = on_disconnect
        self._running = False
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
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._expired_requests: dict[str, None] = {}
        self._event_request_ids: set[str] = set()
        self._last_connection_error: BaseException | None = None

    @property
    def connected(self) -> bool:
        return self._connected.is_set() and self._writer is not None

    @property
    def writer(self) -> asyncio.StreamWriter | None:
        """Identity used to fence execution outcomes to their original socket."""
        return self._writer

    async def start(self) -> None:
        """Start connection management and wait for the first successful handshake."""

        self._ensure_event_loop()
        async with self._start_lock:
            if not self._running:
                self._running = True
                self._reconnect_task = asyncio.create_task(
                    self._connection_supervisor(), name="tay-reconnect"
                )
        await self._wait_until_connected()

    async def close(self) -> None:
        """Stop reconnecting, close the socket, and release pending callers."""

        if self._loop is not None:
            self._ensure_event_loop()
        async with self._start_lock:
            self._running = False
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
            await asyncio.wait_for(
                self._connected.wait(), timeout=self._config.connect_timeout
            )
        except TimeoutError as exc:
            detail = (
                f": {self._last_connection_error}"
                if self._last_connection_error
                else ""
            )
            if isinstance(self._last_connection_error, PermissionError):
                detail += "; check socket permissions and the shared UID/GID or group"
            raise ConnectionLost(
                f"could not connect to Tay at {self._config.socket_path!r} within "
                f"{self._config.connect_timeout:g}s{detail}"
            ) from exc

    async def _connection_supervisor(self) -> None:
        delay = self._config.reconnect_initial_delay
        while self._running:
            writer: asyncio.StreamWriter | None = None
            try:
                self._connection_lost.clear()
                reader, writer = await asyncio.open_unix_connection(
                    self._config.socket_path
                )
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
                delay = self._config.reconnect_initial_delay
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
                delay = min(delay * 2, self._config.reconnect_max_delay)

    async def _detach_connection(self, writer: asyncio.StreamWriter | None) -> None:
        if writer is None:
            return
        reader_task = self._reader_task
        self._on_disconnect(writer)
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

    async def _read_loop(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            while self._running and self._writer is writer:
                message = await read_frame(
                    reader, max_frame_bytes=self._config.max_frame_bytes
                )
                await self._handle_message(message)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            self._last_connection_error = exc
        finally:
            if self._writer is writer:
                self._event_request_ids.clear()
                self._expired_requests.clear()
                self._connected.clear()
                self._connection_lost.set()
                await self._fail_pending(ConnectionLost("connection to Tay was lost"))

    async def _handle_message(self, message: dict[str, Any]) -> None:
        message_type = message["type"]
        if message_type in {"execute", "cancel_execution"}:
            await self._on_execution(message)
            return
        if message_type == "ping":
            await self.send_event("pong", {"ping_id": message.get("ping_id")})
            return

        request_id = message.get("request_id")
        if request_id is not None:
            if request_id in self._expired_requests:
                del self._expired_requests[request_id]
                return
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

    async def _send_envelope(
        self,
        envelope: Mapping[str, Any],
        *,
        connection: asyncio.StreamWriter | None = None,
    ) -> None:
        writer = self._writer if connection is None else connection
        if writer is None or writer.is_closing():
            raise ConnectionLost("Tay socket is not connected")
        frame = encode_frame(envelope, max_frame_bytes=self._config.max_frame_bytes)
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

    async def send_event(
        self,
        message_type: str,
        fields: Mapping[str, Any],
        *,
        connection: asyncio.StreamWriter | None = None,
    ) -> None:
        request_id = uuid.uuid4().hex
        envelope = {
            "version": PROTOCOL_VERSION,
            "type": message_type,
            "request_id": request_id,
            **normalize_json(fields),
        }
        self._event_request_ids.add(request_id)
        try:
            await self._send_envelope(envelope, connection=connection)
        except Exception:
            self._event_request_ids.discard(request_id)
            raise

    async def exchange(
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
            try:
                return await asyncio.wait_for(
                    asyncio.shield(future), timeout=self._config.request_timeout
                )
            except TimeoutError as exc:
                raise ConnectionLost(
                    f"Tay did not reply to {message_type!r} within {self._config.request_timeout:g}s"
                ) from exc
        finally:
            async with self._pending_lock:
                self._pending.pop(request_id, None)
            if not future.done():
                # A cancelled/timed-out caller does not cancel the server's
                # command. Keep bounded tombstones for its eventual reply.
                self._expired_requests[request_id] = None
                if len(self._expired_requests) > 1024:
                    del self._expired_requests[next(iter(self._expired_requests))]
                future.cancel()
            elif not future.cancelled():
                future.exception()
