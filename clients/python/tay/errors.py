"""Errors raised by the Tay Python SDK."""

from __future__ import annotations

from typing import Any


class TayError(Exception):
    """Base class for errors raised by this package."""


class ValidationError(TayError, ValueError):
    """A value cannot safely be represented by protocol v1 JSON."""


class ProtocolError(TayError):
    """The peer sent an invalid or unsupported protocol message."""


class ConnectionLost(TayError, ConnectionError):
    """The connection closed before a request received a reply.

    In particular, an ``enqueue`` that raises this error may already have been
    accepted by Tay.  Use a caller-supplied submission id to reconcile that
    unknown outcome instead of blindly submitting a second job.
    """


class ServerError(TayError):
    """Tay rejected a request."""

    def __init__(
        self, message: str, *, code: str | None = None, details: Any = None
    ) -> None:
        super().__init__(message)
        self.code = code
        self.details = details


class RemoteTaskError(ServerError):
    """A remote task reported a failure while retrieving its result."""


class TaskRegistrationError(TayError):
    """A task name is invalid or collides with another registered callable."""


class TaskNotRegistered(TayError):
    """Tay asked this runtime to execute an unknown task."""


class ResultTooLarge(ValidationError):
    """A task return value exceeds the configured result limit."""


class ModeError(TayError):
    """The operation is not available in the client's selected mode."""
