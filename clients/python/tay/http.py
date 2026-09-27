"""Async HTTP/JSON producer client for Tay's Bandit listener."""

from __future__ import annotations

import asyncio
import ipaddress
import json
import os
import ssl
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
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
from .errors import ConnectionLost, ProtocolError, ValidationError
from .protocol import json_bytes, normalize_json, validate_task_name


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
    """Producer-only HTTP client; workers still use the Unix socket."""

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
        self, method: str, path: str, body: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        def exchange() -> tuple[int, bytes]:
            request = urllib.request.Request(
                self.base_url + path,
                data=json_bytes(body) if body is not None else None,
                method=method,
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
            )
            try:
                with self._opener.open(
                    request, timeout=self.request_timeout
                ) as response:
                    return response.status, response.read(1_048_577)
            except urllib.error.HTTPError as exc:
                if exc.code in (301, 302, 303, 307, 308):
                    raise ProtocolError(
                        "Tay HTTP endpoint redirected the request"
                    ) from exc
                return exc.code, exc.read(1_048_577)
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                raise ConnectionLost(str(exc)) from exc

        status, raw = await asyncio.to_thread(exchange)
        if len(raw) > 1_048_576:
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
