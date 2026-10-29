"""Public Python SDK for Tay's local socket and HTTP/JSON APIs."""

from .client import JobHandle, ScheduleHandle, Tay
from .errors import (
    ConnectionLost,
    JobCancelled,
    ModeError,
    ProtocolError,
    RemoteTaskError,
    ResultMissing,
    ResultTooLarge,
    ServerError,
    TaskNotRegistered,
    TaskRegistrationError,
    TayError,
    ValidationError,
)
from .http import HTTPJobHandle, TayHTTP, TayHTTPWorker
from .socket_path import resolve_socket_path
from .task import Durability, Task

__all__ = [
    "ConnectionLost",
    "Durability",
    "HTTPJobHandle",
    "JobCancelled",
    "JobHandle",
    "ModeError",
    "ProtocolError",
    "RemoteTaskError",
    "ResultMissing",
    "ResultTooLarge",
    "ScheduleHandle",
    "ServerError",
    "Task",
    "TaskNotRegistered",
    "TaskRegistrationError",
    "Tay",
    "TayError",
    "TayHTTP",
    "TayHTTPWorker",
    "ValidationError",
    "resolve_socket_path",
]
