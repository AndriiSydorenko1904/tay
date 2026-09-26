"""Async gRPC producer client for Tay's ``tay.grpc.v1.Tay`` service.

The socket client remains dependency-free.  Install the ``grpc`` extra to use
this transport: ``pip install 'tay-client[grpc]'``.
"""

from __future__ import annotations

import ipaddress
import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Self

from .client import _extract_identifier, _server_error_from_payload
from .errors import (
    ConnectionLost,
    ProtocolError,
    RemoteTaskError,
    ServerError,
    ValidationError,
)
from .protocol import json_bytes, normalize_json, validate_task_name

_SERVICE = "/tay.grpc.v1.Tay/"


def _varint(value: int) -> bytes:
    encoded = bytearray()
    while value > 0x7F:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def _read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ProtocolError("truncated protobuf response")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, offset
    raise ProtocolError("invalid protobuf varint in response")


def _bytes_field(number: int, value: bytes) -> bytes:
    return _varint((number << 3) | 2) + _varint(len(value)) + value


def _decode_bytes_field(data: bytes, wanted: int) -> bytes:
    result = b""
    offset = 0
    while offset < len(data):
        tag, offset = _read_varint(data, offset)
        wire_type = tag & 7
        field = tag >> 3
        if wire_type != 2:
            raise ProtocolError("unsupported protobuf field in gRPC response")
        length, offset = _read_varint(data, offset)
        end = offset + length
        if end > len(data):
            raise ProtocolError("truncated protobuf response field")
        if field == wanted:
            result = data[offset:end]
        offset = end
    return result


@dataclass(frozen=True)
class _EnqueueRequest:
    task: str
    args_json: bytes
    options_json: bytes

    def SerializeToString(self) -> bytes:
        return (
            _bytes_field(1, self.task.encode("utf-8"))
            + _bytes_field(2, self.args_json)
            + _bytes_field(3, self.options_json)
        )


@dataclass(frozen=True)
class _JobRequest:
    job_id: str

    def SerializeToString(self) -> bytes:
        return _bytes_field(1, self.job_id.encode("utf-8"))


@dataclass(frozen=True)
class _OperationReply:
    json: bytes

    @classmethod
    def FromString(cls, value: bytes) -> _OperationReply:
        return cls(_decode_bytes_field(value, 1))


@dataclass(frozen=True)
class GrpcJobHandle:
    """A lightweight reference to a job submitted through :class:`TayGrpc`."""

    id: str
    _tay: TayGrpc

    async def status(self) -> Any:
        reply = await self._tay._job_request("GetJob", self.id)
        return reply.get("status", reply.get("job", reply))

    async def cancel(self) -> Any:
        reply = await self._tay._job_request("Cancel", self.id)
        return reply.get("status", reply)

    async def result(self) -> Any:
        reply = await self._tay._job_request("GetResult", self.id)
        error = reply.get("error")
        if error:
            raise _server_error_from_payload(error)
        return reply.get("result")


class TayGrpc:
    """Async gRPC producer for an explicitly enabled Tay gRPC listener.

    This transport intentionally exposes producer operations only: enqueue,
    status, cancellation, and result retrieval.  Task execution and schedules
    continue to use the Protocol v1 Unix-domain socket.
    """

    def __init__(
        self,
        target: str = "127.0.0.1:50051",
        *,
        request_timeout: float = 30.0,
        tls_ca_file: str | Path | None = None,
        tls_cert_file: str | Path | None = None,
        tls_key_file: str | Path | None = None,
        tls_pkcs12_file: str | Path | None = None,
        tls_pkcs12_password: str | bytes | None = None,
        channel: Any | None = None,
    ) -> None:
        if type(target) is not str or not target.strip() or "\x00" in target:
            raise ValidationError("gRPC target must be a non-empty address string")
        if request_timeout <= 0:
            raise ValidationError("request_timeout must be positive")
        if tls_pkcs12_file is not None and any(
            value is not None for value in (tls_ca_file, tls_cert_file, tls_key_file)
        ):
            raise ValidationError(
                "use either a PKCS#12 bundle or PEM certificate files"
            )
        if tls_pkcs12_file is None and tls_pkcs12_password is not None:
            raise ValidationError("tls_pkcs12_password requires tls_pkcs12_file")

        tls_files = (tls_ca_file, tls_cert_file, tls_key_file)
        if any(value is not None for value in tls_files) and not all(
            value is not None for value in tls_files
        ):
            raise ValidationError(
                "mTLS requires tls_ca_file, tls_cert_file, and tls_key_file"
            )
        if (
            tls_pkcs12_file is None
            and all(value is None for value in tls_files)
            and not _loopback_target(target)
        ):
            raise ValidationError(
                "a non-loopback gRPC target requires mTLS certificates"
            )

        if channel is None:
            try:
                import grpc
            except ImportError as exc:
                raise RuntimeError(
                    "gRPC support requires grpcio; install tay-client[grpc]"
                ) from exc
            if tls_pkcs12_file is not None:
                roots, private_key, certificate_chain = _pkcs12_credentials(
                    tls_pkcs12_file, tls_pkcs12_password
                )
                credentials = grpc.ssl_channel_credentials(
                    root_certificates=roots,
                    private_key=private_key,
                    certificate_chain=certificate_chain,
                )
                channel = grpc.aio.secure_channel(target, credentials)
            elif tls_ca_file is not None:
                credentials = grpc.ssl_channel_credentials(
                    root_certificates=Path(tls_ca_file).read_bytes(),
                    private_key=Path(tls_key_file).read_bytes(),
                    certificate_chain=Path(tls_cert_file).read_bytes(),
                )
                channel = grpc.aio.secure_channel(target, credentials)
            else:
                channel = grpc.aio.insecure_channel(target)

        self.target = target
        self.request_timeout = float(request_timeout)
        self._channel = channel
        self._enqueue_rpc = channel.unary_unary(
            _SERVICE + "Enqueue",
            request_serializer=lambda request: request.SerializeToString(),
            response_deserializer=_OperationReply.FromString,
        )
        self._get_job_rpc = channel.unary_unary(
            _SERVICE + "GetJob",
            request_serializer=lambda request: request.SerializeToString(),
            response_deserializer=_OperationReply.FromString,
        )
        self._cancel_rpc = channel.unary_unary(
            _SERVICE + "Cancel",
            request_serializer=lambda request: request.SerializeToString(),
            response_deserializer=_OperationReply.FromString,
        )
        self._get_result_rpc = channel.unary_unary(
            _SERVICE + "GetResult",
            request_serializer=lambda request: request.SerializeToString(),
            response_deserializer=_OperationReply.FromString,
        )

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    async def close(self) -> None:
        """Close the underlying ``grpc.aio`` channel."""

        result = self._channel.close()
        if result is not None:
            await result

    async def enqueue(
        self,
        task: str,
        args: Mapping[str, Any] | None = None,
        *,
        options: Mapping[str, Any] | None = None,
        **option_keywords: Any,
    ) -> GrpcJobHandle:
        """Submit a task and return its durable job handle."""

        if args is None:
            args = {}
        if not isinstance(args, Mapping):
            raise ValidationError("enqueue args must be a JSON object")
        if not isinstance(options or {}, Mapping):
            raise ValidationError("enqueue options must be a mapping")
        merged_options = dict(options or {})
        overlap = set(merged_options).intersection(option_keywords)
        if overlap:
            raise ValidationError(f"enqueue option supplied twice: {min(overlap)}")
        merged_options.update(option_keywords)
        backoff = merged_options.get("backoff")
        if not (backoff is None or backoff == "exponential"):
            raise ValidationError("Protocol v1 supports only backoff='exponential'")

        reply = await self._invoke(
            self._enqueue_rpc,
            _EnqueueRequest(
                validate_task_name(task),
                json_bytes(normalize_json(args)),
                json_bytes(normalize_json(merged_options)),
            ),
        )
        return GrpcJobHandle(_extract_identifier(reply, "job_id", "job"), self)

    async def _job_request(self, method: str, job_id: str) -> dict[str, Any]:
        if type(job_id) is not str or not job_id or len(job_id.encode("utf-8")) > 128:
            raise ValidationError(
                "job id must be a non-empty UTF-8 string of at most 128 bytes"
            )
        rpc = {
            "GetJob": self._get_job_rpc,
            "Cancel": self._cancel_rpc,
            "GetResult": self._get_result_rpc,
        }[method]
        return await self._invoke(rpc, _JobRequest(job_id))

    async def _invoke(self, rpc: Any, request: Any) -> dict[str, Any]:
        try:
            reply = await rpc(request, timeout=self.request_timeout)
        except Exception as exc:
            raise _grpc_error(exc) from exc
        try:
            decoded = json.loads(reply.json.decode("utf-8"))
        except (AttributeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProtocolError("Tay sent an invalid gRPC JSON response") from exc
        if not isinstance(decoded, dict):
            raise ProtocolError("Tay gRPC response must contain a JSON object")
        return decoded


def _grpc_error(exc: Exception) -> ServerError:
    code = getattr(exc, "code", lambda: None)()
    details = getattr(exc, "details", lambda: None)() or str(exc)
    name = getattr(code, "name", None)
    if name == "UNAVAILABLE":
        return ConnectionLost(str(details))
    if name == "ABORTED":
        return RemoteTaskError(str(details), code="task_failed")
    return ServerError(
        str(details), code=name.lower() if isinstance(name, str) else None
    )


def _loopback_target(target: str) -> bool:
    if target.startswith("["):
        host, separator, _ = target[1:].partition("]:")
    else:
        host, separator, _ = target.partition(":")
    if not separator:
        return False
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _pkcs12_credentials(
    bundle_file: str | Path, password: str | bytes | None
) -> tuple[bytes, bytes, bytes]:
    try:
        from cryptography import x509
        from cryptography.exceptions import UnsupportedAlgorithm
        from cryptography.hazmat.primitives.serialization import (
            Encoding,
            NoEncryption,
            PrivateFormat,
            pkcs12,
        )
    except ImportError as exc:
        raise RuntimeError(
            "PKCS#12 support requires cryptography; install tay-client[grpc-pkcs12]"
        ) from exc

    if password is not None and not isinstance(password, (str, bytes)):
        raise ValidationError("tls_pkcs12_password must be a string or bytes")
    password_bytes = password.encode("utf-8") if isinstance(password, str) else password

    try:
        key, certificate, additional = pkcs12.load_key_and_certificates(
            Path(bundle_file).read_bytes(), password_bytes
        )
    except (ValueError, UnsupportedAlgorithm) as exc:
        raise ValidationError("invalid PKCS#12 bundle or password") from exc

    if key is None or certificate is None:
        raise ValidationError(
            "PKCS#12 bundle must contain a client key and certificate"
        )

    ca_certificates = []
    for candidate in additional or []:
        try:
            constraints = candidate.extensions.get_extension_for_class(
                x509.BasicConstraints
            ).value
        except x509.ExtensionNotFound:
            continue
        if constraints.ca:
            ca_certificates.append(candidate)
    if not ca_certificates:
        raise ValidationError("PKCS#12 bundle must include a trusted CA certificate")

    roots = b"".join(ca.public_bytes(Encoding.PEM) for ca in ca_certificates)
    private_key = key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    chain = certificate.public_bytes(Encoding.PEM) + roots
    return roots, private_key, chain
