from __future__ import annotations

import asyncio
import contextlib
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import ConnectionLost, Tay
from tay.errors import ProtocolError
from tay.protocol import encode_frame, read_frame


class LateSocketReplyTests(unittest.IsolatedAsyncioTestCase):
    async def exercise_late_reply(self, cancel_caller: bool) -> None:
        entered, cancelled = asyncio.Event(), asyncio.Event()
        request_received, release_reply = asyncio.Event(), asyncio.Event()
        handlers: set[asyncio.Task] = set()

        async def peer(reader, writer):
            handler = asyncio.current_task()
            handlers.add(handler)
            try:
                while True:
                    message = await read_frame(reader)
                    kind = message["type"]
                    if kind == "status":
                        request_received.set()
                        await release_reply.wait()
                    reply_type = {
                        "hello": "hello_ok",
                        "register_tasks": "registered",
                        "started": "accepted",
                        "failed": "accepted",
                        "status": "status",
                    }[kind]
                    writer.write(
                        encode_frame(
                            {
                                "version": 1,
                                "type": reply_type,
                                "request_id": message["request_id"],
                                "status": "available",
                            }
                        )
                    )
                    await writer.drain()
                    if kind == "register_tasks":
                        writer.write(
                            encode_frame(
                                {
                                    "version": 1,
                                    "type": "execute",
                                    "request_id": "execution",
                                    "execution_id": "execution",
                                    "reservation_id": "reservation",
                                    "job_id": "2" * 32,
                                    "task": "audit.running",
                                    "args": {},
                                }
                            )
                        )
                        await writer.drain()
            except (ConnectionLost, ConnectionError, asyncio.IncompleteReadError):
                pass
            finally:
                writer.close()
                with contextlib.suppress(Exception):
                    await writer.wait_closed()
                handlers.discard(handler)

        with tempfile.TemporaryDirectory(prefix="tay-late-", dir="/tmp") as directory:
            socket_path = str(pathlib.Path(directory) / "tay.sock")
            listener = await asyncio.start_unix_server(peer, path=socket_path)
            client = Tay(
                socket_path=socket_path,
                request_timeout=0.1,
                connect_timeout=2,
                reconnect_initial_delay=0.5,
            )

            @client.task(name="audit.running")
            async def running():
                entered.set()
                try:
                    await asyncio.Event().wait()
                finally:
                    cancelled.set()

            try:
                await client.start()
                await asyncio.wait_for(entered.wait(), 2)
                connection = client._writer
                caller = asyncio.create_task(
                    client._request("status", {"job_id": "1" * 32})
                )
                await asyncio.wait_for(request_received.wait(), 2)
                if cancel_caller:
                    caller.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await caller
                else:
                    with self.assertRaises(ConnectionLost):
                        await caller
                self.assertEqual(len(client._expired_requests), 1)
                release_reply.set()
                # An answer to a subsequent command proves the earlier reply
                # was consumed on the same ordered socket stream.
                reply = await client._request("status", {"job_id": "3" * 32})
                self.assertEqual(reply["status"], "available")
                self.assertIs(client._writer, connection)
                self.assertTrue(client.connected)
                self.assertFalse(cancelled.is_set())
                self.assertEqual(client._expired_requests, {})
            finally:
                release_reply.set()
                executions = tuple(client._executions.values())
                await client.close()
                await asyncio.gather(*executions, return_exceptions=True)
                listener.close()
                await listener.wait_closed()
                await asyncio.gather(*tuple(handlers), return_exceptions=True)

    async def test_late_timeout_reply_does_not_cancel_unrelated_execution(self):
        await self.exercise_late_reply(cancel_caller=False)

    async def test_late_cancelled_caller_reply_keeps_the_same_connection(self):
        await self.exercise_late_reply(cancel_caller=True)

    async def test_expired_request_tracking_is_bounded_and_unknown_replies_still_fail(
        self,
    ):
        client = Tay(socket_path="/tmp/tay-expired-test.sock")
        client._writer = object()
        client._send_envelope = AsyncMock()
        for _ in range(1030):
            caller = asyncio.create_task(client._exchange("status", {}))
            await asyncio.sleep(0)
            caller.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await caller
        self.assertEqual(len(client._expired_requests), 1024)
        known = next(iter(client._expired_requests))
        await client._handle_message({"type": "status", "request_id": known})
        self.assertEqual(len(client._expired_requests), 1023)
        with self.assertRaises(ProtocolError):
            await client._handle_message(
                {"type": "status", "request_id": "unsolicited"}
            )
        client._writer = None
