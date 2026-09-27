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
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Self

try:
    from cryptography import x509
    from cryptography.exceptions import UnsupportedAlgorithm
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PrivateFormat,
        pkcs12,
    )
except ModuleNotFoundError as exc:
    if exc.name != "cryptography" and not exc.name.startswith("cryptography."):
        raise
    x509 = None

from .client import _extract_identifier, _server_error_from_payload
from .errors import ConnectionLost, ProtocolError, ServerError, ValidationError
from .protocol import json_bytes, normalize_json, validate_task_name
from .task import Task, TaskConfig

# Buffer at most one MiB plus one byte to detect an oversized response.
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
        **option_keywords: Any,
    ) -> HTTPJobHandle:
        if args is None:
            args = {}
        if not isinstance(args, Mapping) or not isinstance(options or {}, Mapping):
            raise ValidationError("enqueue args and options must be JSON objects")
        merged = dict(options or {})
        if merged.keys() & option_keywords.keys():
            raise ValidationError("enqueue option supplied twice")
        merged.update(option_keywords)
        if merged.get("backoff") not in (None, "exponential"):
            raise ValidationError("Protocol v1 supports only backoff='exponential'")
        reply = await self._request(
            "POST",
            "/jobs",
            {
                "task": validate_task_name(task),
                "args": normalize_json(args),
                "options": normalize_json(merged),
            },
        )
        return HTTPJobHandle(_extract_identifier(reply, "job_id", "job"), self)

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

    def task(
        self, function: Callable[..., Any] | None = None, *, name: str | None = None
    ):
        def register(fn: Callable[..., Any]) -> Task:
            key = validate_task_name(name or f"{fn.__module__}.{fn.__name__}")
            if key in self._tasks:
                raise ValidationError(f"task {key!r} is already registered")
            declared = Task(self, fn, name=key, config=TaskConfig())
            self._tasks[key] = declared
            return declared

        return register(function) if function is not None else register

    async def start(self) -> None:
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
        token = reply.get("worker_token")
        if type(token) is not str or len(token) != _WORKER_TOKEN_LENGTH:
            raise ProtocolError("Tay did not return a valid worker token")
        self._token = token

    async def close(self) -> None:
        token, self._token = self._token, None
        if token is not None:
            with contextlib.suppress(ConnectionLost, ServerError):
                await self._request(
                    "DELETE", "/workers", headers={"Authorization": f"Bearer {token}"}
                )
        await super().close()

    async def run(self) -> None:
        """Poll until cancelled; keep polling while tasks execute."""
        await self.start()
        try:
            await self._run_loop()
        finally:
            await self.close()

    async def _run_loop(self) -> None:
        while True:
            try:
                message = await self._worker_request(
                    "POST", f"/queues/{self.queue}/claim"
                )
            except ConnectionLost:
                await asyncio.sleep(_WORKER_RETRY_DELAY_SECONDS)
                continue
            except ServerError as exc:
                if exc.code == "unknown_worker":
                    self._token = None
                    await self.start()
                    continue
                if exc.code == "claim_in_progress":
                    await asyncio.sleep(_WORKER_RETRY_DELAY_SECONDS)
                    continue
                raise
            kind = message.get("type")
            if kind == "execute":
                execution = message.get("execution_id")
                if type(execution) is not str:
                    raise ProtocolError("execute is missing execution_id")
                if execution not in self._executions:
                    declared = self._tasks.get(message.get("task"))
                    self._execution_is_sync[execution] = (
                        declared is not None
                        and not inspect.iscoroutinefunction(declared.function)
                    )
                    task = asyncio.create_task(self._execute(message))
                    self._executions[execution] = task
                    task.add_done_callback(
                        lambda done, key=execution: self._execution_finished(key, done)
                    )
            elif kind == "cancel_execution":
                key = message.get("execution_id")
                execution = self._executions.get(key)
                if execution is not None and not self._execution_is_sync.get(
                    key, False
                ):
                    execution.cancel()
            elif message:
                raise ProtocolError(f"unexpected worker event {kind!r}")

    def _execution_finished(self, key: str, task: asyncio.Task[None]) -> None:
        self._executions.pop(key, None)
        self._execution_is_sync.pop(key, None)
        if not task.cancelled() and (error := task.exception()) is not None:
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
        task = self._tasks.get(message.get("task"))
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
            if inspect.iscoroutinefunction(task.function):
                result = task._call_from_arguments(message["args"])
            else:
                result = await asyncio.to_thread(
                    task._call_from_arguments, message["args"]
                )
            if inspect.isawaitable(result):
                result = await result
            result = normalize_json(result)
            if len(json_bytes(result)) > _MAX_TASK_RESULT_BYTES:
                raise ValidationError(
                    f"task result exceeds {_MAX_TASK_RESULT_BYTES} bytes"
                )
            completion = {**context, "outcome": "success", "result": result}
        except asyncio.CancelledError:
            completion = {
                **context,
                "outcome": "failure",
                "error": {"type": "CancelledError", "message": "cancelled"},
            }
        except Exception as exc:  # noqa: BLE001 - user task errors become failures
            completion = {
                **context,
                "outcome": "failure",
                "error": {
                    "type": type(exc).__name__[:_MAX_ERROR_TYPE_CHARACTERS],
                    "message": str(exc)[:_MAX_ERROR_MESSAGE_CHARACTERS],
                },
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
