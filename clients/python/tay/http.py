"""Async HTTP/JSON producer client for Tay's Bandit listener."""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import ipaddress
import json
import os
import ssl
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import warnings
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from typing import Any, Self

x509: Any = None
try:
    from cryptography import x509 as _x509
    from cryptography.exceptions import UnsupportedAlgorithm
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PrivateFormat,
        pkcs12,
    )

    x509 = _x509
except ModuleNotFoundError as exc:
    missing = exc.name or ""
    if missing != "cryptography" and not missing.startswith("cryptography."):
        raise

from .client import (
    _extract_identifier,
    _extract_job_durability,
    _server_error_from_payload,
)
from .errors import (
    ConnectionLost,
    ProtocolError,
    ServerError,
    TaskRegistrationError,
    ValidationError,
)
from .execution import cancel_async_execution, error_details, run_task
from .job_options import enqueue_payload, validate_durability
from .protocol import json_bytes, validate_task_name
from .task import Durability, Task, TaskConfig

# Buffer at most one MB plus one byte to detect an oversized response.
_MAX_HTTP_RESPONSE_BYTES = 1_048_576
_MAX_TASK_RESULT_BYTES = 65_536
_MAX_WORKER_CAPACITY = 256
_MIN_WORKER_REQUEST_TIMEOUT_SECONDS = 25
_WORKER_RETRY_DELAY_SECONDS = 1
_WORKER_TOKEN_LENGTH = 43
_MAX_ERROR_TYPE_CHARACTERS = 128
_MAX_ERROR_MESSAGE_CHARACTERS = 1_024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


@dataclass(frozen=True)
class HTTPJobHandle:
    id: str
    _tay: TayHTTP
    durability: Durability | None = None

    async def status(self) -> Any:
        reply = await self._tay._request("GET", f"/jobs/{self.id}")
        return reply.get("status", reply.get("job", reply))

    async def cancel(self) -> Any:
        reply = await self._tay._request("DELETE", f"/jobs/{self.id}")
        return reply.get("status", reply)

    async def result(self) -> Any:
        reply = await self._tay._request("GET", f"/jobs/{self.id}/result")
        if reply.get("error"):
            raise _server_error_from_payload(reply["error"])
        return reply.get("result")


class TayHTTP:
    """HTTP/JSON producer client for a local or mTLS-protected Tay listener."""

    def __init__(
        self,
        base_url: str = "http://127.0.0.1:8080",
        *,
        request_timeout: float = 30.0,
        tls_ca_file: str | Path | None = None,
        tls_cert_file: str | Path | None = None,
        tls_key_file: str | Path | None = None,
        tls_pkcs12_file: str | Path | None = None,
        tls_pkcs12_password: str | bytes | None = None,
    ) -> None:
        parsed = urllib.parse.urlsplit(base_url)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
            or parsed.username
            or parsed.password
        ):
            raise ValidationError("base_url must be an HTTP(S) origin")
        try:
            port = parsed.port
        except ValueError as exc:
            raise ValidationError("base_url must contain a valid port") from exc
        if port is not None and not 1 <= port <= 65535:
            raise ValidationError("base_url must contain a valid port")
        if request_timeout <= 0:
            raise ValidationError("request_timeout must be positive")
        files = (tls_ca_file, tls_cert_file, tls_key_file)
        if tls_pkcs12_file is not None and any(item is not None for item in files):
            raise ValidationError("use either PKCS#12 or PEM credentials")
        if tls_pkcs12_file is None and tls_pkcs12_password is not None:
            raise ValidationError("tls_pkcs12_password requires tls_pkcs12_file")
        if any(item is not None for item in files) and not all(
            item is not None for item in files
        ):
            raise ValidationError("mTLS requires CA, certificate and key files")
        try:
            loopback = ipaddress.ip_address(parsed.hostname).is_loopback
        except ValueError:
            loopback = parsed.hostname == "localhost"
        if not loopback and (
            parsed.scheme != "https"
            or (tls_ca_file is None and tls_pkcs12_file is None)
        ):
            raise ValidationError("remote HTTP targets require HTTPS and mTLS")
        if (
            tls_ca_file is not None or tls_pkcs12_file is not None
        ) and parsed.scheme != "https":
            raise ValidationError("mTLS requires an HTTPS URL")
        context = None
        if parsed.scheme == "https":
            if tls_pkcs12_file is not None:
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            else:
                context = ssl.create_default_context(
                    cafile=str(tls_ca_file) if tls_ca_file else None
                )
            if tls_cert_file is not None:
                context.load_cert_chain(str(tls_cert_file), str(tls_key_file))
            if tls_pkcs12_file is not None:
                _load_pkcs12(context, tls_pkcs12_file, tls_pkcs12_password)
        self.base_url = base_url.rstrip("/")
        self.request_timeout = request_timeout
        self._context = context
        handler = (
            urllib.request.HTTPSHandler(context=context)
            if context
            else urllib.request.HTTPHandler()
        )
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), handler, _NoRedirect()
        )

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    async def close(self) -> None:
        """No persistent transport resources are held."""

    async def enqueue(
        self,
        task: str,
        args: Mapping[str, Any] | None = None,
        *,
        options: Mapping[str, Any] | None = None,
        durability: Durability | None = None,
        **option_keywords: Any,
    ) -> HTTPJobHandle:
        payload = enqueue_payload(
            validate_task_name(task), args, options, option_keywords, durability
        )
        reply = await self._request("POST", "/jobs", payload)
        return HTTPJobHandle(
            _extract_identifier(reply, "job_id", "job"),
            self,
            _extract_job_durability(reply),
        )

    async def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        def exchange() -> tuple[int, bytes]:
            request = urllib.request.Request(
                self.base_url + path,
                data=json_bytes(body) if body is not None else None,
                method=method,
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    **(headers or {}),
                },
            )
            try:
                with self._opener.open(
                    request, timeout=self.request_timeout
                ) as response:
                    return response.status, response.read(_MAX_HTTP_RESPONSE_BYTES + 1)
            except urllib.error.HTTPError as exc:
                if exc.code in (301, 302, 303, 307, 308):
                    raise ProtocolError(
                        "Tay HTTP endpoint redirected the request"
                    ) from exc
                return exc.code, exc.read(_MAX_HTTP_RESPONSE_BYTES + 1)
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                raise ConnectionLost(str(exc)) from exc

        status, raw = await asyncio.to_thread(exchange)
        if status == 204 and raw == b"":
            return {}
        if len(raw) > _MAX_HTTP_RESPONSE_BYTES:
            raise ProtocolError("Tay HTTP response is too large")
        try:
            reply = json.loads(raw)
        except (ValueError, UnicodeDecodeError) as exc:
            raise ProtocolError("Tay sent invalid HTTP JSON") from exc
        if not isinstance(reply, dict):
            raise ProtocolError("Tay HTTP response must be a JSON object")
        if isinstance(reply.get("error"), dict):
            raise _server_error_from_payload(reply["error"])
        if not 200 <= status < 300:
            raise ProtocolError(f"Tay HTTP returned unexpected status {status}")
        return reply


class TayHTTPWorker(TayHTTP):
    """Remote worker using bounded HTTP long polling and the same mTLS transport."""

    def __init__(
        self,
        base_url: str,
        *,
        queue: str = "default",
        capacity: int = 1,
        runtime_id: str | None = None,
        **transport_options: Any,
    ) -> None:
        super().__init__(base_url, **transport_options)
        if self.request_timeout < _MIN_WORKER_REQUEST_TIMEOUT_SECONDS:
            raise ValidationError(
                "HTTP workers require request_timeout >= "
                f"{_MIN_WORKER_REQUEST_TIMEOUT_SECONDS} seconds"
            )
        if type(capacity) is not int or not 1 <= capacity <= _MAX_WORKER_CAPACITY:
            raise ValidationError(
                f"capacity must be between 1 and {_MAX_WORKER_CAPACITY}"
            )
        self.queue = validate_task_name(queue)
        self.capacity = capacity
        self.runtime_id = runtime_id or f"http-worker-{uuid.uuid4().hex}"
        self._tasks: dict[str, Task] = {}
        self._token: str | None = None
        self._executions: dict[str, asyncio.Task[None]] = {}
        self._execution_is_sync: dict[str, bool] = {}
        self._serve_task: asyncio.Task[Any] | None = None
        self._close_lock = asyncio.Lock()
        self._closing = False

    @property
    def tasks(self) -> Mapping[str, Task]:
        """Read-only view of handlers registered on this worker."""

        return self._tasks.copy()

    def task(
        self,
        function: Callable[..., Any] | None = None,
        *,
        name: str | None = None,
        retries: int | None = None,
        backoff: str | None = None,
        durability: Durability | None = None,
    ) -> Task | Callable[[Callable[..., Any]], Task]:
        """Register a callable, either as ``@worker.task`` or ``@worker.task(...)``."""

        if retries is not None and (
            type(retries) is not int or retries not in range(65_535)
        ):
            raise ValidationError("retries must be an integer in 0..65534")
        if backoff is not None and backoff != "exponential":
            raise ValidationError("backoff must be 'exponential'")
        validate_durability(durability)

        config = TaskConfig(retries=retries, backoff=backoff, durability=durability)

        def register(fn: Callable[..., Any]) -> Task:
            if not callable(fn):
                raise TaskRegistrationError("only callables can be registered as tasks")
            key = validate_task_name(name or f"{fn.__module__}.{fn.__name__}")
            existing = self._tasks.get(key)
            if existing is not None:
                if existing.function is fn:
                    return existing
                raise TaskRegistrationError(
                    f"task name {key!r} is already registered to another callable"
                )
            declared = Task(self, fn, name=key, config=config)
            self._tasks[key] = declared
            return declared

        return register(function) if function is not None else register

    async def register(self) -> None:
        """Register this worker's task capabilities and obtain a session token.

        Registration alone does not claim or execute jobs.  Use
        :meth:`serve_forever` to run the worker loop.
        """
        if self._token is not None:
            return
        if not self._tasks:
            raise ValidationError(
                "register at least one task before starting the worker"
            )
        reply = await self._request(
            "POST",
            "/workers",
            {
                "runtime_id": self.runtime_id,
                "tasks": list(self._tasks),
                "capacity": self.capacity,
                "queue": self.queue,
            },
        )
        if self._closing:
            raise ConnectionLost("HTTP worker was closed during registration")
        token = reply.get("worker_token")
        if type(token) is not str or len(token) != _WORKER_TOKEN_LENGTH:
            raise ProtocolError("Tay did not return a valid worker token")
        self._token = token

    async def start(self) -> None:
        """Deprecated alias for :meth:`register`."""
        warnings.warn(
            "TayHTTPWorker.start() only registers the worker; use register() "
            "or serve_forever() instead",
            DeprecationWarning,
            stacklevel=2,
        )
        await self.register()

    async def close(self) -> None:
        """Stop claiming, cancel and await executions, then revoke the session.

        A synchronous function may continue in its thread; its cancelled
        asyncio wrapper cannot submit a late completion after shutdown.
        """
        self._closing = True
        serving = self._serve_task
        current = asyncio.current_task()
        if serving is not None and serving is not current and not serving.cancelling():
            serving.cancel()

        # serve_forever's finally block also closes the worker. Never await
        # that task while holding the resource lock that its cleanup needs.
        async with self._close_lock:
            token, self._token = self._token, None
            executions = tuple(
                task for task in self._executions.values() if task is not current
            )
            for task in executions:
                task.cancel()
            await asyncio.gather(*executions, return_exceptions=True)
            self._executions.clear()
            self._execution_is_sync.clear()
            if token is not None:
                with contextlib.suppress(ConnectionLost, ServerError):
                    await self._request(
                        "DELETE",
                        "/workers",
                        headers={"Authorization": f"Bearer {token}"},
                    )
            await super().close()

        if serving is not None and serving is not current:
            await asyncio.gather(serving, return_exceptions=True)

    async def serve_forever(self) -> None:
        """Register, then claim and execute jobs until cancelled or closed."""
        if self._serve_task is not None or self._close_lock.locked():
            raise RuntimeError("HTTP worker is already serving or closing")
        self._closing = False
        self._serve_task = asyncio.current_task()
        try:
            await self.register()
            await self._run_loop()
        finally:
            try:
                await self.close()
            finally:
                self._serve_task = None

    async def run(self) -> None:
        """Deprecated alias for :meth:`serve_forever`."""
        warnings.warn(
            "TayHTTPWorker.run() is deprecated; use serve_forever() instead",
            DeprecationWarning,
            stacklevel=2,
        )
        await self.serve_forever()

    async def _run_loop(self) -> None:
        while not self._closing:
            try:
                message = await self._worker_request(
                    "POST", f"/queues/{self.queue}/claim"
                )
            except ConnectionLost:
                if self._closing:
                    return
                await asyncio.sleep(_WORKER_RETRY_DELAY_SECONDS)
                continue
            except ServerError as exc:
                if self._closing:
                    return
                if exc.code == "unknown_worker":
                    self._token = None
                    await self.register()
                    continue
                if exc.code == "claim_in_progress":
                    await asyncio.sleep(_WORKER_RETRY_DELAY_SECONDS)
                    continue
                raise
            if self._closing:
                return
            kind = message.get("type")
            if kind == "execute":
                execution = message.get("execution_id")
                if type(execution) is not str:
                    raise ProtocolError("execute is missing execution_id")
                if execution not in self._executions:
                    task_name = message.get("task")
                    if type(task_name) is not str:
                        raise ProtocolError("execute is missing task")
                    declared = self._tasks.get(task_name)
                    self._execution_is_sync[execution] = (
                        declared is not None
                        and not inspect.iscoroutinefunction(declared.function)
                    )
                    task = asyncio.create_task(self._execute(message))
                    self._executions[execution] = task

                    task.add_done_callback(partial(self._execution_finished, execution))
            elif kind == "cancel_execution":
                key = message.get("execution_id")
                if type(key) is not str:
                    raise ProtocolError("cancel_execution is missing execution_id")
                execution = self._executions.get(key)
                cancel_async_execution(
                    execution, self._execution_is_sync.get(key, False)
                )
            elif message:
                raise ProtocolError(f"unexpected worker event {kind!r}")

    def _execution_finished(self, key: str, task: asyncio.Task[None]) -> None:
        self._executions.pop(key, None)
        self._execution_is_sync.pop(key, None)
        if (
            not task.cancelled()
            and (error := task.exception()) is not None
            and not self._closing
        ):
            asyncio.get_running_loop().call_exception_handler(
                {
                    "message": "Tay HTTP worker could not settle execution",
                    "exception": error,
                }
            )

    async def _worker_request(
        self, method: str, path: str, body: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        if self._token is None:
            raise ConnectionLost("worker is not registered")
        return await self._request(
            method, path, body, headers={"Authorization": f"Bearer {self._token}"}
        )

    async def _execute(self, message: dict[str, Any]) -> None:
        context = {
            "reservation_id": message["reservation_id"],
            "execution_id": message["execution_id"],
        }
        task_name = message.get("task")
        if type(task_name) is not str:
            raise ProtocolError("execute is missing task")
        task = self._tasks.get(task_name)
        if task is None:
            await self._worker_request(
                "POST",
                "/workers/complete",
                {
                    **context,
                    "outcome": "failure",
                    "error": {"type": "TaskNotRegistered"},
                },
            )
            return
        await self._worker_request("POST", "/workers/started", context)
        try:
            result = await run_task(
                task,
                message["args"],
                synchronous=not inspect.iscoroutinefunction(task.function),
                max_result_bytes=_MAX_TASK_RESULT_BYTES,
                on_awaitable=lambda: self._execution_is_sync.update(
                    {message["execution_id"]: False}
                ),
                size_error=lambda _size, limit: ValidationError(
                    f"task result exceeds {limit} bytes"
                ),
            )
            completion = {**context, "outcome": "success", "result": result}
        except asyncio.CancelledError:
            if self._closing:
                raise
            completion = {
                **context,
                "outcome": "failure",
                "error": {"type": "CancelledError", "message": "cancelled"},
            }
        except Exception as exc:  # noqa: BLE001 - user task errors become failures
            completion = {
                **context,
                "outcome": "failure",
                "error": error_details(
                    exc,
                    max_type_characters=_MAX_ERROR_TYPE_CHARACTERS,
                    max_message_characters=_MAX_ERROR_MESSAGE_CHARACTERS,
                ),
            }
        await self._worker_request("POST", "/workers/complete", completion)


def _load_pkcs12(
    context: ssl.SSLContext, bundle_file: str | Path, password: str | bytes | None
) -> None:
    if x509 is None:
        raise RuntimeError(
            "PKCS#12 requires cryptography; install tay-client[http-pkcs12]"
        )
    if password is not None and not isinstance(password, (str, bytes)):
        raise ValidationError("tls_pkcs12_password must be a string or bytes")
    password_bytes = password.encode() if isinstance(password, str) else password
    try:
        key, cert, additional = pkcs12.load_key_and_certificates(
            Path(bundle_file).read_bytes(), password_bytes
        )
    except (ValueError, UnsupportedAlgorithm) as exc:
        raise ValidationError("invalid PKCS#12 bundle or password") from exc
    if key is None or cert is None:
        raise ValidationError(
            "PKCS#12 bundle must contain a client key and certificate"
        )
    roots = []
    for candidate in additional or []:
        try:
            if candidate.extensions.get_extension_for_class(
                x509.BasicConstraints
            ).value.ca:
                roots.append(candidate)
        except x509.ExtensionNotFound:
            continue
    if not roots:
        raise ValidationError("PKCS#12 bundle must include a trusted CA certificate")
    context.load_verify_locations(
        cadata=b"".join(root.public_bytes(Encoding.PEM) for root in roots).decode()
    )
    with tempfile.TemporaryDirectory(prefix="tay-http-tls-") as directory:
        key_path = Path(directory) / "client.key"
        cert_path = Path(directory) / "client.pem"
        for path, data in (
            (
                key_path,
                key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()),
            ),
            (cert_path, cert.public_bytes(Encoding.PEM)),
        ):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
        context.load_cert_chain(str(cert_path), str(key_path))
