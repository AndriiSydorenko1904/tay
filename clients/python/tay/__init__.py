"""Public Python SDK for the Tay Protocol v1 local executor endpoint."""

from .client import JobHandle, ScheduleHandle, Tay
from .errors import (
    ConnectionLost,
    ModeError,
    ProtocolError,
    RemoteTaskError,
    ResultTooLarge,
    ServerError,
    TaskNotRegistered,
    TaskRegistrationError,
    TayError,
    ValidationError,
)
from .grpc import GrpcJobHandle, TayGrpc
from .socket_path import resolve_socket_path
from .task import Task

__all__ = [
    "ConnectionLost",
    "GrpcJobHandle",
    "JobHandle",
    "ModeError",
    "ProtocolError",
    "RemoteTaskError",
    "ResultTooLarge",
    "ScheduleHandle",
    "ServerError",
    "Task",
    "TaskNotRegistered",
    "TaskRegistrationError",
    "Tay",
    "TayError",
    "TayGrpc",
    "ValidationError",
    "resolve_socket_path",
]
