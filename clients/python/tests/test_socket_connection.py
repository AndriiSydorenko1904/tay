from __future__ import annotations

import asyncio
import contextlib
import pathlib
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import ConnectionLost, ServerError, Tay
from tay.protocol import encode_frame, read_frame
from tay.socket_connection import SocketConnection


@contextlib.asynccontextmanager
async def socket_listener(peer):
    handlers, writers = [], []

    async def handle(reader, writer):
        handlers.append(asyncio.current_task())
        writers.append(writer)
        try:
            await peer(reader, writer)
        except (ConnectionLost, ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    with tempfile.TemporaryDirectory(prefix="tay-conn-", dir="/tmp") as directory:
        path = str(pathlib.Path(directory) / "tay.sock")
        listener = await asyncio.start_unix_server(handle, path=path)
        try:
            yield path
        finally:
            listener.close()
            await listener.wait_closed()
            for writer in writers:
                writer.close()
            for handler in handlers:
                handler.cancel()
            results = await asyncio.gather(*handlers, return_exceptions=True)
            for result in results:
                if isinstance(result, BaseException) and not isinstance(
                    result, asyncio.CancelledError
                ):
                    raise result


async def reply(writer, message, kind, **fields):
    writer.write(
        encode_frame(
            {
                "version": 1,
                "type": kind,
                "request_id": message["request_id"],
                **fields,
            }
        )
    )
    await writer.drain()


class SocketConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_transport_correlates_reordered_replies_without_a_client(self):
        async def peer(reader, writer):
            await reply(writer, await read_frame(reader), "hello_ok")
            first, second = await read_frame(reader), await read_frame(reader)
            await reply(writer, second, "status", value=second["value"])
            for kind in ["execute", "cancel_execution", "ping"]:
                await reply(writer, {"request_id": kind}, kind, ping_id="ping")
            await reply(writer, first, "status", value=first["value"])
            pong = await read_frame(reader)
            self.assertEqual(pong["type"], "pong")
            self.assertEqual(pong["ping_id"], "ping")
            await reply(writer, pong, "heartbeat_ok")
            rejected = await read_frame(reader)
            await reply(
                writer, rejected, "error", error={"code": "capacity", "message": "full"}
            )
            await reader.read()

        async with socket_listener(peer) as path:
            config = SimpleNamespace(
                socket_path=path,
                max_frame_bytes=1_048_576,
                request_timeout=1.0,
                connect_timeout=1.0,
                reconnect_initial_delay=0.01,
                reconnect_max_delay=0.05,
            )
            executions, disconnected = AsyncMock(), Mock()

            async def bootstrap():
                await connection.exchange("hello", {})

            connection = SocketConnection(
                config,
                bootstrap=bootstrap,
                on_execution=executions,
                on_disconnect=disconnected,
            )
            try:
                await connection.start()
                writer = connection.writer
                first, second = await asyncio.gather(
                    connection.exchange("status", {"value": 1}),
                    connection.exchange("status", {"value": 2}),
                )
                self.assertEqual([first["value"], second["value"]], [1, 2])
                self.assertEqual(
                    [call.args[0]["type"] for call in executions.await_args_list],
                    ["execute", "cancel_execution"],
                )
                with self.assertRaises(ServerError) as caught:
                    await connection.exchange("enqueue", {})
                self.assertEqual(caught.exception.code, "capacity")
                self.assertTrue(connection.connected)
                self.assertIs(connection.writer, writer)
            finally:
                await connection.close()
            disconnected.assert_called_once_with(writer)
            self.assertFalse(connection.connected)

    async def exercise_reconnect(self, synchronous):
        entered, cancelled = asyncio.Event(), asyncio.Event()
        thread_entered, release = threading.Event(), threading.Event()
        sessions = []

        async def peer(reader, writer):
            messages = []
            sessions.append(messages)
            first_session = len(sessions) == 1
            while True:
                message = await read_frame(reader)
                messages.append(message)
                kind = message["type"]
                if kind == "enqueue":
                    # The submission may have been accepted. Drop its reply;
                    # reconnect must reconcile declarations without replaying it.
                    return
                await reply(
                    writer,
                    message,
                    {
                        "hello": "hello_ok",
                        "schedule": "scheduled",
                        "register_tasks": "registered",
                        "started": "accepted",
                        "status": "status",
                    }[kind],
                    status="available",
                )
                if kind == "register_tasks" and first_session:
                    await reply(
                        writer,
                        {"request_id": "execute"},
                        "execute",
                        task="tests.running",
                        execution_id="old-execution",
                        reservation_id="old-reservation",
                        job_id="1" * 32,
                        args={},
                    )

        async with socket_listener(peer) as path:
            client = Tay(
                socket_path=path,
                request_timeout=1,
                connect_timeout=1,
                reconnect_initial_delay=0.01,
                reconnect_max_delay=0.05,
            )

            if synchronous:

                @client.task(name="tests.running", every={"seconds": 60})
                def running():
                    thread_entered.set()
                    release.wait(5)
                    return "old result"

            else:

                @client.task(name="tests.running", every={"seconds": 60})
                async def running():
                    entered.set()
                    try:
                        await asyncio.Event().wait()
                    finally:
                        cancelled.set()

            executions = ()
            try:
                self.assertIs(await client.start(), client)
                if synchronous:
                    self.assertTrue(await asyncio.to_thread(thread_entered.wait, 1))
                else:
                    await asyncio.wait_for(entered.wait(), 1)
                old_writer = client._connection.writer
                executions = tuple(client._executions.values())
                with self.assertRaises(ConnectionLost):
                    await client.enqueue("tests.running", {"submission": "once"})
                await client.start()
                self.assertIsNot(client._connection.writer, old_writer)
                if synchronous:
                    # Synchronous work retains its capacity until its thread
                    # returns, even after reconnecting to a fresh socket.
                    self.assertIn("old-execution", client._executions)
                else:
                    await asyncio.wait_for(cancelled.wait(), 1)
                release.set()
                await asyncio.wait_for(
                    asyncio.gather(*executions, return_exceptions=True), 1
                )
                status = await client._request("status", {"job_id": "2" * 32})
                self.assertEqual(status["status"], "available")
                self.assertEqual(len(sessions), 2)
                for messages in sessions:
                    self.assertEqual(
                        [message["type"] for message in messages[:3]],
                        ["hello", "schedule", "register_tasks"],
                    )
                self.assertEqual(
                    [message["type"] for message in sessions[1]],
                    ["hello", "schedule", "register_tasks", "status"],
                )
                self.assertEqual(
                    sum(m["type"] == "enqueue" for s in sessions for m in s), 1
                )
            finally:
                release.set()
                await client.close()
                await asyncio.gather(*executions, return_exceptions=True)

    async def test_reconnect_cancels_async_work_and_does_not_replay_submission(self):
        await self.exercise_reconnect(synchronous=False)

    async def test_sync_completion_after_reconnect_stays_on_its_original_socket(self):
        await self.exercise_reconnect(synchronous=True)
