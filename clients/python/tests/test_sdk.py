from __future__ import annotations

import asyncio
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import ProtocolError, Tay, ValidationError, resolve_socket_path
from tay.protocol import decode_payload, encode_frame, normalize_json


class ProtocolTests(unittest.TestCase):
    def test_frames_are_bounded_and_require_public_envelope_fields(self) -> None:
        message = {"version": 1, "type": "hello", "request_id": "request-1"}
        self.assertEqual(decode_payload(encode_frame(message)[4:]), message)

        with self.assertRaises(ProtocolError):
            encode_frame({"version": 1, "type": "hello"})
        with self.assertRaises(ValidationError):
            normalize_json({"value": object()})


class SocketPathTests(unittest.TestCase):
    def test_explicit_and_environment_overrides_win(self) -> None:
        self.assertEqual(
            resolve_socket_path(
                "/chosen/tay.sock",
                environ={"TAY_SOCKET_PATH": "/environment/tay.sock"},
                uid=4242,
            ),
            "/chosen/tay.sock",
        )
        self.assertEqual(
            resolve_socket_path(
                environ={"TAY_SOCKET_PATH": "/environment/tay.sock"}, uid=4242
            ),
            "/environment/tay.sock",
        )

    def test_automatic_resolution_matches_protocol_contract(self) -> None:
        always_usable = lambda _path: True
        self.assertEqual(
            resolve_socket_path(
                environ={"XDG_RUNTIME_DIR": "/runtime", "TMPDIR": "/temporary"},
                uid=4242,
                usable_directory=always_usable,
            ),
            "/runtime/tay/tay.sock",
        )
        self.assertEqual(
            resolve_socket_path(
                environ={"TMPDIR": "/temporary"}, uid=4242, usable_directory=always_usable
            ),
            "/temporary/tay-4242/tay.sock",
        )
        self.assertEqual(resolve_socket_path(environ={}, uid=4242), "/tmp/tay-4242/tay.sock")
        self.assertNotEqual(
            resolve_socket_path(environ={}, uid=101), resolve_socket_path(environ={}, uid=202)
        )

    def test_invalid_configured_path_is_not_silently_replaced(self) -> None:
        with self.assertRaises(ValidationError):
            resolve_socket_path("relative.sock", environ={}, uid=1)
        with self.assertRaises(ValidationError):
            resolve_socket_path(environ={"TAY_SOCKET_PATH": "relative.sock"}, uid=1)


class ClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_listener_bounds_are_validated_before_connecting(self) -> None:
        with self.assertRaises(ValidationError):
            Tay(capacity=65_536)
        with self.assertRaises(ValidationError):
            Tay(client_id="\x00")
        with self.assertRaises(ValidationError):
            Tay().task(backoff="fixed")

    async def test_bootstrap_uses_listener_v1_field_names(self) -> None:
        client = Tay(mode="client", client_id="producer-1")
        calls: list[tuple[str, dict[str, object]]] = []

        async def exchange(kind: str, fields: dict[str, object]) -> dict[str, object]:
            calls.append((kind, dict(fields)))
            return {"type": "hello_ok", "request_id": "request-1"}

        client._exchange = exchange  # type: ignore[method-assign]
        await client._bootstrap()
        self.assertEqual(
            calls,
            [
                (
                    "hello",
                    {"mode": "client", "runtime_id": "producer-1", "max_concurrency": 0},
                )
            ],
        )

    async def test_execution_events_keep_the_reservation_fence(self) -> None:
        client = Tay(mode="embedded", client_id="worker-1")
        events: list[tuple[str, dict[str, object]]] = []

        @client.task(name="tests.add")
        def add(left: int, right: int) -> dict[str, int]:
            return {"sum": left + right}

        async def send_event(kind: str, fields: dict[str, object]) -> None:
            events.append((kind, dict(fields)))

        client._send_event = send_event  # type: ignore[method-assign]
        await client._accept_execution(
            {
                "reservation_id": "reservation-1",
                "execution_id": "execution-1",
                "job_id": "job-1",
                "task": "tests.add",
                "args": {"left": 3, "right": 4},
            }
        )

        for _ in range(50):
            if not client._executions:
                break
            await asyncio.sleep(0.01)

        self.assertEqual([kind for kind, _ in events], ["started", "succeeded"])
        self.assertTrue(all(fields["reservation_id"] == "reservation-1" for _, fields in events))
        self.assertEqual(events[-1][1]["result"], {"sum": 7})
