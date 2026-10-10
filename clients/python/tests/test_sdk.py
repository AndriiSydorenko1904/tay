from __future__ import annotations

import asyncio
import importlib
import pathlib
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import (
    HTTPJobHandle,
    ProtocolError,
    ServerError,
    TaskRegistrationError,
    Tay,
    TayHTTP,
    TayHTTPWorker,
    ValidationError,
    resolve_socket_path,
)
from tay.client import _server_error_from_payload
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
        def always_usable(_path: str) -> bool:
            return True

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
                environ={"TMPDIR": "/temporary"},
                uid=4242,
                usable_directory=always_usable,
            ),
            "/temporary/tay-4242/tay.sock",
        )
        self.assertEqual(
            resolve_socket_path(environ={}, uid=4242), "/tmp/tay-4242/tay.sock"
        )
        self.assertNotEqual(
            resolve_socket_path(environ={}, uid=101),
            resolve_socket_path(environ={}, uid=202),
        )

    def test_invalid_configured_path_is_not_silently_replaced(self) -> None:
        with self.assertRaises(ValidationError):
            resolve_socket_path("relative.sock", environ={}, uid=1)
        with self.assertRaises(ValidationError):
            resolve_socket_path(environ={"TAY_SOCKET_PATH": "relative.sock"}, uid=1)


class ClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_task_decorator_uses_module_function_name_and_metadata(self) -> None:
        client = Tay(mode="client")

        @client.task
        def refresh(account_id: str) -> str:
            """Refresh one account."""
            return account_id

        expected_name = f"{refresh.__module__}.refresh"
        self.assertEqual(refresh.name, expected_name)
        self.assertEqual(refresh.__name__, "refresh")
        self.assertEqual(refresh.__doc__, "Refresh one account.")
        self.assertIs(client.tasks[expected_name], refresh)
        self.assertEqual(refresh("account-1"), "account-1")

    async def test_task_decorator_accepts_explicit_public_name(self) -> None:
        client = Tay(mode="client")

        @client.task(name="accounts.refresh.v1")
        def refresh(account_id: str) -> None:
            return None

        self.assertEqual(refresh.name, "accounts.refresh.v1")
        self.assertIs(client.tasks["accounts.refresh.v1"], refresh)

    async def test_decorated_task_enqueue_serializes_call_arguments(self) -> None:
        client = Tay(mode="client")
        calls: list[tuple[str, dict[str, object]]] = []

        async def request(kind: str, fields: dict[str, object]) -> dict[str, object]:
            calls.append((kind, fields))
            return {"job_id": "job-1"}

        client._request = request  # type: ignore[method-assign]

        @client.task(name="accounts.refresh.v1")
        def refresh(account_id: str, *, force: bool = False) -> None:
            return None

        job = await refresh.enqueue("account-1", force=True, delay=5)
        self.assertEqual(job.id, "job-1")
        self.assertEqual(
            calls,
            [
                (
                    "enqueue",
                    {
                        "task": "accounts.refresh.v1",
                        "args": {"account_id": "account-1", "force": True},
                        "options": {"delay": 5},
                    },
                )
            ],
        )

    async def test_task_decorator_options_are_enqueue_defaults_and_can_be_overridden(
        self,
    ) -> None:
        client = Tay(mode="client")
        calls: list[tuple[str, dict[str, object]]] = []

        async def request(kind: str, fields: dict[str, object]) -> dict[str, object]:
            calls.append((kind, fields))
            return {"job_id": "job-1"}

        client._request = request  # type: ignore[method-assign]

        @client.task(name="accounts.retry.v1", retries=3, backoff="exponential")
        def retry(account_id: str) -> None:
            return None

        await retry.enqueue("account-1")
        await retry.enqueue("account-2", retries=0)

        self.assertEqual(
            [fields["options"] for _, fields in calls],
            [
                {"retries": 3, "backoff": "exponential"},
                {"retries": 0, "backoff": "exponential"},
            ],
        )

    async def test_task_decorator_rejects_duplicate_names(self) -> None:
        client = Tay(mode="client")

        @client.task(name="accounts.refresh.v1")
        def first() -> None:
            return None

        with self.assertRaisesRegex(TaskRegistrationError, "accounts.refresh.v1"):

            @client.task(name="accounts.refresh.v1")
            def second() -> None:
                return None

        self.assertIs(client.tasks["accounts.refresh.v1"], first)

    async def test_async_decorated_handler_executes_from_registry(self) -> None:
        client = Tay(mode="embedded", client_id="worker-async")
        events: list[tuple[str, dict[str, object]]] = []

        @client.task(name="accounts.async_refresh.v1")
        async def refresh(account_id: str) -> dict[str, str]:
            await asyncio.sleep(0)
            return {"account_id": account_id}

        async def send_event(kind: str, fields: dict[str, object]) -> None:
            events.append((kind, dict(fields)))

        client._send_event = send_event  # type: ignore[method-assign]
        await client._accept_execution(
            {
                "reservation_id": "reservation-async",
                "execution_id": "execution-async",
                "job_id": "job-async",
                "task": refresh.name,
                "args": {"account_id": "account-1"},
            }
        )
        while client._executions:
            await asyncio.sleep(0)

        self.assertEqual([kind for kind, _ in events], ["started", "succeeded"])
        self.assertEqual(events[-1][1]["result"], {"account_id": "account-1"})

    async def test_capacity_error_preserves_machine_readable_reason(self) -> None:
        error = _server_error_from_payload(
            {"code": "capacity", "reason": "client_slots"}
        )
        self.assertIsInstance(error, ServerError)
        self.assertEqual(error.code, "capacity")
        self.assertEqual(error.details["reason"], "client_slots")

    async def test_server_error_message_includes_code_without_reason(self) -> None:
        error = _server_error_from_payload({"code": "unavailable"})
        self.assertEqual(str(error), "Tay rejected the request (unavailable)")
        self.assertEqual(error.code, "unavailable")
        self.assertEqual(error.details, {"code": "unavailable"})

    async def test_http_client_uses_json_endpoints(self) -> None:
        client = TayHTTP()
        calls = []

        async def request(method, path, body=None):
            calls.append((method, path, body))
            return {"job_id": "http-job", "result": 42}

        client._request = request
        job = await client.enqueue("tests.http", {"value": 1})
        self.assertIsInstance(job, HTTPJobHandle)
        self.assertEqual(job.id, "http-job")
        self.assertEqual(await job.result(), 42)
        self.assertEqual(calls[0][0:2], ("POST", "/jobs"))
        self.assertEqual(calls[1][0:2], ("GET", "/jobs/http-job/result"))

    async def test_http_worker_task_accepts_retry_defaults(self) -> None:
        worker = TayHTTPWorker("http://127.0.0.1:8080")

        @worker.task(name="tests.http.retry", retries=4, backoff="exponential")
        def retry(value: int) -> int:
            return value

        self.assertEqual(retry.config.retries, 4)
        self.assertEqual(retry.config.backoff, "exponential")

        with self.assertRaisesRegex(ValidationError, "0..65534"):
            worker.task(name="tests.invalid", retries=65_535)

    async def test_http_response_limit_reads_only_one_extra_byte(self) -> None:
        module = importlib.import_module("tay.http")
        client = TayHTTP()
        requested_sizes = []

        class OversizedResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

            def read(self, size):
                requested_sizes.append(size)
                return b"x" * size

        with (
            patch.object(client._opener, "open", return_value=OversizedResponse()),
            self.assertRaisesRegex(ProtocolError, "response is too large"),
        ):
            await client._request("GET", "/jobs/test")

        self.assertEqual(requested_sizes, [module._MAX_HTTP_RESPONSE_BYTES + 1])

    async def test_http_requires_mtls_for_remote_targets(self) -> None:
        with self.assertRaises(ValidationError):
            TayHTTP("http://tay.example:8080")
        with self.assertRaises(ValidationError):
            TayHTTP("https://tay.example:8080")
        with self.assertRaises(ValidationError):
            TayHTTP("http://127.0.0.1:8080", tls_pkcs12_file="client.p12")
        with self.assertRaises(ValidationError):
            TayHTTPWorker("http://127.0.0.1:8080", capacity=0)
        with self.assertRaises(ValidationError):
            TayHTTPWorker("http://127.0.0.1:8080", request_timeout=5)

    async def test_pkcs12_extra_is_optional_for_socket_and_plain_http(self) -> None:
        module = importlib.import_module("tay.http")
        with (
            patch.object(module, "x509", None),
            self.assertRaisesRegex(RuntimeError, r"tay-client\[http-pkcs12\]"),
        ):
            module._load_pkcs12(object(), "unused.p12", None)

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
                    {
                        "mode": "client",
                        "runtime_id": "producer-1",
                        "max_concurrency": 0,
                    },
                )
            ],
        )

    async def test_task_capabilities_can_be_changed_after_startup(self) -> None:
        client = Tay(mode="worker", client_id="worker-1")

        @client.task(name="tests.first")
        def first() -> None:
            return None

        @client.task(name="tests.second")
        def second() -> None:
            return None

        calls: list[tuple[str, dict[str, object]]] = []

        async def request(kind: str, fields: dict[str, object]) -> dict[str, object]:
            calls.append((kind, dict(fields)))
            return {"type": "tasks_changed"}

        client._request = request  # type: ignore[method-assign]
        self.assertEqual(await client.unregister_tasks(first), ("tests.first",))
        self.assertEqual(await client.register_tasks("tests.first"), (first,))
        self.assertEqual(
            calls,
            [
                ("unregister_tasks", {"tasks": ["tests.first"]}),
                ("register_tasks", {"tasks": ["tests.first"]}),
            ],
        )

        bootstrap_calls: list[tuple[str, dict[str, object]]] = []

        async def exchange(kind: str, fields: dict[str, object]) -> dict[str, object]:
            bootstrap_calls.append((kind, dict(fields)))
            return {"type": "ok"}

        client._exchange = exchange  # type: ignore[method-assign]
        await client._bootstrap()
        self.assertEqual(
            bootstrap_calls[-1],
            ("register_tasks", {"tasks": ["tests.first", "tests.second"]}),
        )

    async def test_client_mode_rejects_task_capability_changes(self) -> None:
        client = Tay(mode="client")

        @client.task(name="tests.local")
        def local() -> None:
            return None

        with self.assertRaisesRegex(Exception, "client mode"):
            await client.register_tasks(local)
        with self.assertRaisesRegex(Exception, "client mode"):
            await client.unregister_tasks(local)

    async def test_static_schedule_declarations_replay_during_bootstrap(self) -> None:
        client = Tay(mode="embedded")

        @client.task(
            name="tests.periodic",
            every={"seconds": 30},
            declaration_id="tests-periodic-v1",
        )
        def periodic() -> None:
            return None

        calls: list[tuple[str, dict[str, object]]] = []

        async def exchange(kind: str, fields: dict[str, object]) -> dict[str, object]:
            calls.append((kind, dict(fields)))
            return {"type": "ok"}

        client._exchange = exchange  # type: ignore[method-assign]
        await client._bootstrap()
        self.assertEqual(calls[0][0], "hello")
        self.assertEqual(
            calls[1],
            (
                "schedule",
                {
                    "task": "tests.periodic",
                    "args": {},
                    "options": {},
                    "every": {"seconds": 30},
                    "declaration_id": "tests-periodic-v1",
                },
            ),
        )
        self.assertEqual(calls[2], ("register_tasks", {"tasks": ["tests.periodic"]}))

    async def test_schedule_payload_supports_timezone_catch_up_and_delayed_start(
        self,
    ) -> None:
        client = Tay(mode="client")
        requests: list[tuple[str, dict[str, object]]] = []

        async def request(kind: str, fields: dict[str, object]) -> dict[str, object]:
            requests.append((kind, dict(fields)))
            return {"schedule_id": "schedule-1"}

        client._request = request  # type: ignore[method-assign]
        handle = await client.schedule(
            "tests.report",
            cron="*/15 * * * *",
            timezone="+02",
            catch_up="all",
            delay=30,
        )
        self.assertEqual(handle.id, "schedule-1")
        self.assertEqual(
            requests,
            [
                (
                    "schedule",
                    {
                        "task": "tests.report",
                        "args": {},
                        "cron": "*/15 * * * *",
                        "timezone": "+02",
                        "catch_up": "all",
                        "delay": 30,
                        "options": {},
                    },
                )
            ],
        )

        bootstrap_calls: list[tuple[str, dict[str, object]]] = []

        async def exchange(kind: str, fields: dict[str, object]) -> dict[str, object]:
            bootstrap_calls.append((kind, dict(fields)))
            return {"type": "ok"}

        client._exchange = exchange  # type: ignore[method-assign]
        await client._bootstrap()
        self.assertIn(
            (
                "schedule",
                {
                    "task": "tests.report",
                    "args": {},
                    "cron": "*/15 * * * *",
                    "timezone": "+02",
                    "catch_up": "all",
                    "delay": 30,
                    "options": {},
                    "declaration_id": "schedule-1",
                },
            ),
            bootstrap_calls,
        )

        client._request = request  # type: ignore[method-assign]
        await handle.cancel()
        bootstrap_calls.clear()
        await client._bootstrap()
        self.assertFalse(any(kind == "schedule" for kind, _ in bootstrap_calls))

        with self.assertRaisesRegex(ValidationError, "either delay or start_at"):
            await client.every("tests.report", minutes=5, delay=1, start_at=2)

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
        self.assertTrue(
            all(fields["reservation_id"] == "reservation-1" for _, fields in events)
        )
        self.assertEqual(events[-1][1]["result"], {"sum": 7})
