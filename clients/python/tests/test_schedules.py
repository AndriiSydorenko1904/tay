from __future__ import annotations

import sys
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tay import ProtocolError, Tay, TayHTTP, TayHTTPWorker, ValidationError


class ScheduleParityTests(unittest.IsolatedAsyncioTestCase):
    async def test_transports_share_payloads_and_schedule_handles(self) -> None:
        payloads: list[tuple[str, dict[str, Any]]] = []

        async def request(operation: str, payload: dict[str, Any]) -> dict[str, Any]:
            payloads.append((operation, payload))
            if operation == "schedule":
                return {"schedule_id": payload["declaration_id"]}
            if operation == "schedules":
                return {"schedules": [{"id": "stable"}]}
            return {"schedule": {"id": "stable", "overlap": "queue"}}

        clients = [Tay(mode="client"), TayHTTP("http://127.0.0.1:1")]
        for client in clients:
            client._schedule_request = request  # type: ignore[method-assign]
            handle = await client.every(
                "task.v1",
                minutes=5,
                declaration_id="stable",
                overlap="queue",
                catch_up="all",
                start_at=1000,
                retries=2,
            )
            self.assertEqual(handle.id, "stable")
            self.assertEqual((await handle.status())["overlap"], "queue")
            self.assertEqual(await client.schedules(), [{"id": "stable"}])
            await handle.cancel()
        self.assertEqual(payloads[:4], payloads[4:])

    async def test_both_transports_follow_pages_and_refuse_nonadvancing_cursors(
        self,
    ) -> None:
        requests: list[dict[str, Any]] = []
        for client in [Tay(mode="client"), TayHTTP("http://127.0.0.1:1")]:
            requests.clear()

            async def request(
                operation: str, payload: dict[str, Any]
            ) -> dict[str, Any]:
                requests.append(payload)
                if not payload:
                    return {"schedules": [{"id": "a"}], "next_cursor": "a"}
                return {"schedules": [{"id": "b"}], "next_cursor": None}

            client._schedule_request = request  # type: ignore[method-assign]
            self.assertEqual(await client.schedules(), [{"id": "a"}, {"id": "b"}])
            self.assertEqual(requests, [{}, {"cursor": "a"}])

            async def repeated(
                operation: str, payload: dict[str, Any]
            ) -> dict[str, Any]:
                return {"schedules": [], "next_cursor": "a"}

            client._schedule_request = repeated  # type: ignore[method-assign]
            with self.assertRaises(ProtocolError):
                await client.schedules()

    async def test_invalid_schedule_options_fail_before_network_for_both_transports(
        self,
    ) -> None:
        for client in [Tay(mode="client"), TayHTTP("http://127.0.0.1:1")]:
            for options in [
                {"seconds": True},
                {"seconds": 0.0001},
                {"seconds": float("inf")},
                {"seconds": 1, "minutes": 1},
                {"seconds": 1, "overlap": "invalid"},
                {"seconds": 1, "declaration_id": "x" * 129},
                {"seconds": 1, "start_at": 1, "delay": 1},
            ]:
                with (
                    self.subTest(options=options, transport=type(client).__name__),
                    self.assertRaises(ValidationError),
                ):
                    await client.every("task.v1", **options)

    async def test_http_worker_decorators_accept_the_shared_schedule_contract(
        self,
    ) -> None:
        worker = TayHTTPWorker("http://127.0.0.1:1")

        @worker.task(
            name="scheduled.v1",
            every={"minutes": 5},
            overlap="skip",
            declaration_id="static",
        )
        def task() -> None:
            pass

        declaration = task.static_schedule_declaration()  # type: ignore[union-attr]
        self.assertIsNotNone(declaration)
        assert declaration is not None
        self.assertEqual(declaration["declaration_id"], "static")
        self.assertEqual(declaration["overlap"], "skip")
