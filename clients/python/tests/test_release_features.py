from __future__ import annotations

import asyncio
import contextlib
import io
import json
import pathlib
import signal
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import (
    ConnectionLost,
    HTTPJobHandle,
    JobCancelled,
    JobHandle,
    ProtocolError,
    RemoteTaskError,
    ResultMissing,
    ServerError,
    Tay,
    TayHTTP,
    TayHTTPWorker,
    ValidationError,
)
from tay.__main__ import _instance, _serve, main
from tay.doctor import diagnose_http, diagnose_socket
from tay.job_options import ENQUEUE_OPTION_NAMES, enqueue_payload
from tay.responses import _server_error_from_payload


class OptionsContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_shared_options_contract_accepts_and_rejects_identically(self):
        contract = json.loads(
            (pathlib.Path(__file__).parent / "fixtures/job_options_v1.json").read_text()
        )
        self.assertEqual(set(contract["option_names"]), ENQUEUE_OPTION_NAMES)
        for fixture in contract["cases"]:
            for client in [Tay(socket_path="/tmp/tay-options.sock"), TayHTTP()]:
                client._request = AsyncMock(return_value={"job_id": "job"})
                with self.subTest(
                    fixture=fixture["name"], transport=type(client).__name__
                ):
                    if fixture["valid"]:
                        await client.enqueue("task", {}, options=fixture["options"])
                        self.assertEqual(
                            client._request.await_args.args[-1]["options"],
                            fixture["options"],
                        )
                    else:
                        with self.assertRaises(ValidationError):
                            await client.enqueue("task", {}, options=fixture["options"])
                        client._request.assert_not_awaited()
        for value in [float("nan"), float("inf"), -float("inf")]:
            for field in ["delay", "timeout"]:
                with self.assertRaises(ValidationError):
                    enqueue_payload("task", {}, {field: value}, {}, None)


class WaitResultTests(unittest.IsolatedAsyncioTestCase):
    def handles(self):
        for client, handle in [
            (Tay(socket_path="/tmp/tay-result.sock"), JobHandle),
            (TayHTTP(), HTTPJobHandle),
        ]:
            yield client, handle("job", client)

    async def test_waits_without_resubmitting_and_returns_null_false_and_objects(self):
        for client, handle in self.handles():
            for result in [None, False, {"value": 42}]:
                client._request = AsyncMock(
                    side_effect=[
                        ServerError("pending", code="result_not_ready"),
                        {"result": result},
                    ]
                )
                self.assertEqual(
                    await handle.wait_result(timeout=1, poll_interval=0.001), result
                )
                self.assertEqual(client._request.await_count, 2)
                self.assertTrue(
                    all(
                        call.args[0] in ["result", "GET"]
                        for call in client._request.await_args_list
                    )
                )

    async def test_terminal_errors_are_typed_and_never_polled_again(self):
        for code, kind in [
            ("task_cancelled", JobCancelled),
            ("result_missing", ResultMissing),
            ("task_failed", RemoteTaskError),
            ("not_found", ServerError),
            ("unavailable", ServerError),
        ]:
            for client, handle in self.handles():
                client._request = AsyncMock(
                    side_effect=_server_error_from_payload({"code": code})
                )
                with self.assertRaises(kind):
                    await handle.wait_result(timeout=1)
                client._request.assert_awaited_once()

    async def test_one_deadline_covers_network_and_polling_without_cancelling_job(self):
        for client, handle in self.handles():
            cancelled = asyncio.Event()

            async def blocked(*args, cancelled=cancelled):
                try:
                    await asyncio.Event().wait()
                finally:
                    cancelled.set()

            client._request = AsyncMock(side_effect=blocked)
            with self.assertRaises(TimeoutError):
                await handle.wait_result(timeout=0.02)
            self.assertTrue(cancelled.is_set())
            client._request.assert_awaited_once()
            client._request = AsyncMock(
                side_effect=ServerError("pending", code="result_not_ready")
            )
            with self.assertRaises(TimeoutError):
                await handle.wait_result(timeout=0.02, poll_interval=10)
            client._request.assert_awaited_once()

    async def test_external_cancellation_and_bad_inputs_remain_local(self):
        for client, handle in self.handles():
            client._request = AsyncMock(
                side_effect=ServerError("pending", code="result_not_ready")
            )
            waiter = asyncio.create_task(handle.wait_result(timeout=10))
            await asyncio.sleep(0)
            waiter.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await waiter
            for value in [0, -1, True, float("nan"), float("inf")]:
                with self.assertRaises(ValidationError):
                    await handle.wait_result(timeout=value)
            client._request = AsyncMock(return_value={})
            with self.assertRaises(ProtocolError):
                await handle.result()

    async def test_socket_wait_deadline_releases_pending_rpc_during_write_and_reply(
        self,
    ):
        client = Tay(socket_path="/tmp/tay-wait-rpc.sock")
        client._writer = MagicMock()
        client.start = AsyncMock(return_value=client)
        handle = JobHandle("job", client)

        async def blocked_write(*args, **kwargs):
            await asyncio.Event().wait()

        client._send_envelope = AsyncMock(side_effect=blocked_write)
        with self.assertRaises(TimeoutError):
            await handle.wait_result(timeout=0.02)
        self.assertEqual(client._pending, {})
        client._send_envelope = AsyncMock()
        with self.assertRaises(TimeoutError):
            await handle.wait_result(timeout=0.02)
        self.assertEqual(client._pending, {})
        client._writer = None
        await client.close()


class SessionTests(unittest.IsolatedAsyncioTestCase):
    async def test_http_re_registration_waits_for_sync_work_and_never_rebinds_completion(
        self,
    ):
        worker = TayHTTPWorker("http://127.0.0.1:8080", capacity=1)
        worker._token = "old"
        entered = threading.Event()
        release = threading.Event()
        events = []

        def slow():
            entered.set()
            release.wait(2)
            return 42

        worker.task(slow, name="slow")
        worker._request = AsyncMock(
            side_effect=lambda method, path, body=None, **kw: (
                events.append((path, kw)) or {"worker_token": "n" * 43}
            )
        )
        execution = asyncio.create_task(
            worker._execute(
                {
                    "reservation_id": "r",
                    "execution_id": "e",
                    "task": "slow",
                    "args": {},
                },
                session_token="old",
            )
        )
        worker._executions["e"] = execution
        worker._execution_is_sync["e"] = True
        execution.add_done_callback(
            lambda task, worker=worker: worker._execution_finished("e", task)
        )
        try:
            self.assertTrue(await asyncio.to_thread(entered.wait, 1))
            worker._token = None  # Tay restart retires the old session.
            registering = asyncio.create_task(worker.register())
            await asyncio.sleep(0)
            self.assertFalse(registering.done())
            self.assertEqual([path for path, _ in events], ["/workers/started"])
            release.set()
            await asyncio.wait_for(registering, 1)
            await execution
            self.assertEqual(worker._token, "n" * 43)
            self.assertEqual(
                [path for path, _ in events], ["/workers/started", "/workers"]
            )
            self.assertEqual(events[0][1]["headers"]["Authorization"], "Bearer old")
            self.assertEqual(worker._executions, {})
        finally:
            release.set()
            await worker.close()

    async def test_retired_http_async_work_and_awaitables_are_cancelled(self):
        for synchronous in [False, True]:
            worker = TayHTTPWorker("http://127.0.0.1:8080")
            worker._token = "old"
            entered = asyncio.Event()
            release = threading.Event()

            async def forever(entered=entered):
                entered.set()
                await asyncio.Event().wait()

            def returns_coroutine(release=release, forever=forever):
                release.wait(2)
                return forever()

            worker.task(returns_coroutine if synchronous else forever, name="task")
            worker._request = AsyncMock(return_value={"worker_token": "n" * 43})
            execution = asyncio.create_task(
                worker._execute(
                    {
                        "reservation_id": "r",
                        "execution_id": "e",
                        "task": "task",
                        "args": {},
                    },
                    session_token="old",
                )
            )
            worker._executions["e"] = execution
            worker._execution_is_sync["e"] = synchronous
            execution.add_done_callback(
                lambda task, worker=worker: worker._execution_finished("e", task)
            )
            if not synchronous:
                await asyncio.wait_for(entered.wait(), 1)
            else:
                while not worker._request.await_count:
                    await asyncio.sleep(0)
            worker._token = None
            registering = asyncio.create_task(worker.register())
            release.set()
            await asyncio.wait_for(registering, 1)
            await asyncio.gather(execution, return_exceptions=True)
            self.assertFalse(
                any(
                    call.args[1] == "/workers/complete"
                    for call in worker._request.await_args_list
                )
            )
            await worker.close()

    async def test_old_http_session_cannot_send_or_start_against_new_token(self):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker._token = "new"
        worker._request = AsyncMock()
        effect = MagicMock()
        worker.task(effect, name="task")
        await worker._execute(
            {"task": "task", "reservation_id": "r", "execution_id": "e", "args": {}},
            session_token="old",
        )
        effect.assert_not_called()
        worker._request.assert_not_awaited()
        with self.assertRaises(ConnectionLost):
            await worker._worker_request(
                "POST", "/workers/complete", {}, session_token="old"
            )

    async def test_socket_capacity_and_completion_stay_bound_to_original_connection(
        self,
    ):
        client = Tay(mode="worker", capacity=1, socket_path="/tmp/tay-session.sock")
        old = MagicMock()
        old.is_closing.return_value = False
        old.drain = AsyncMock()
        new = MagicMock()
        new.is_closing.return_value = False
        new.drain = AsyncMock()
        client._writer = old
        entered = threading.Event()
        release = threading.Event()
        effects = []

        @client.task(name="slow")
        def slow():
            effects.append("started")
            entered.set()
            release.wait(2)
            return 42

        message = {
            "job_id": "job",
            "task": "slow",
            "args": {},
            "reservation_id": "r",
            "execution_id": "e",
        }
        await client._accept_execution(message)
        try:
            self.assertTrue(await asyncio.to_thread(entered.wait, 1))
            client._writer = new
            with patch.object(
                client, "_execution_failure", new_callable=AsyncMock
            ) as refused:
                await client._accept_execution({**message, "execution_id": "new"})
                refused.assert_awaited_once()
            release.set()
            await asyncio.gather(*tuple(client._executions.values()))
            self.assertEqual(effects, ["started"])
            self.assertEqual(
                old.write.call_count, 1
            )  # STARTED belongs to the old socket.
            new.write.assert_not_called()
        finally:
            release.set()
            await client.close()

    async def test_socket_rechecks_session_after_started_ack_before_user_effect(self):
        client = Tay(mode="worker", socket_path="/tmp/tay-started-race.sock")
        old, new = MagicMock(), MagicMock()
        client._writer = old
        effect = MagicMock()
        task = client.task(effect, name="effect")

        async def started(*args, **kwargs):
            client._writer = new

        client._send_event = AsyncMock(side_effect=started)
        await client._run_execution("r", "e", "j", task, {}, True, connection=old)
        effect.assert_not_called()
        await client.close()


class CLITests(unittest.IsolatedAsyncioTestCase):
    async def test_explicit_and_module_discovery_support_both_workers(self):
        for worker in [
            Tay(mode="worker", socket_path="/tmp/tay-cli.sock"),
            TayHTTPWorker("http://127.0.0.1:8080"),
        ]:
            module = types.ModuleType("cli_fixture")
            module.worker = worker
            with patch.dict(sys.modules, {"cli_fixture": module}):
                self.assertIs(_instance("cli_fixture"), worker)
                self.assertIs(_instance("cli_fixture:worker"), worker)

    async def test_shutdown_closes_during_startup_and_worker_failures_propagate(self):
        for worker in [
            Tay(mode="worker", socket_path="/tmp/tay-cli.sock"),
            TayHTTPWorker("http://127.0.0.1:8080"),
        ]:
            stopped = asyncio.Event()
            entered = asyncio.Event()

            async def blocked(entered=entered):
                entered.set()
                await asyncio.Event().wait()

            if isinstance(worker, Tay):
                worker.start = AsyncMock(side_effect=blocked)
            else:
                worker.serve_forever = AsyncMock(side_effect=blocked)
            worker.close = AsyncMock()
            serving = asyncio.create_task(_serve(worker, stopped=stopped))
            await entered.wait()
            stopped.set()
            await asyncio.wait_for(serving, 1)
            worker.close.assert_awaited_once()
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker.serve_forever = AsyncMock(side_effect=ProtocolError("bad protocol"))
        worker.close = AsyncMock()
        with self.assertRaises(ProtocolError):
            await _serve(worker, stopped=asyncio.Event())
        worker.close.assert_awaited_once()

    async def test_real_signal_handlers_are_removed_after_shutdown(self):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker.serve_forever = AsyncMock(side_effect=lambda: asyncio.Event().wait())
        worker.close = AsyncMock()
        callbacks = {}
        loop = asyncio.get_running_loop()

        async def blocked():
            await asyncio.Event().wait()

        worker.serve_forever = AsyncMock(side_effect=blocked)
        with (
            patch.object(
                loop,
                "add_signal_handler",
                side_effect=lambda sig, fn: callbacks.update({sig: fn}),
            ),
            patch.object(loop, "remove_signal_handler") as remove,
        ):
            runner = asyncio.create_task(_serve(worker))
            while signal.SIGTERM not in callbacks:
                await asyncio.sleep(0)
            callbacks[signal.SIGTERM]()
            await asyncio.wait_for(runner, 1)
            self.assertEqual(remove.call_count, 2)

    async def test_socket_doctor_connects_without_sending_or_creating_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(pathlib.Path(directory) / "tay.sock")
            received = []

            async def connection(reader, writer):
                received.append(await reader.read())
                writer.close()
                await writer.wait_closed()

            server = await asyncio.start_unix_server(connection, path)
            async with server:
                report = await diagnose_socket(path)
                self.assertTrue(report["ok"])
                self.assertEqual(report["source"], "argument")
                await asyncio.sleep(0)
            self.assertTrue(all(data == b"" for data in received))
            missing = await diagnose_socket(
                str(pathlib.Path(directory) / "missing.sock")
            )
            self.assertFalse(missing["ok"])
            plain = pathlib.Path(directory) / "file"
            plain.write_text("unchanged")
            self.assertFalse((await diagnose_socket(str(plain)))["ok"])
            self.assertEqual(plain.read_text(), "unchanged")

    async def test_http_doctor_checks_only_health_and_never_prints_credentials(self):
        with patch.object(
            TayHTTP,
            "_request",
            new_callable=AsyncMock,
            return_value={"type": "health", "state": "ready"},
        ) as request:
            report = await diagnose_http("http://127.0.0.1:8080")
            self.assertTrue(report["ok"])
            request.assert_awaited_once_with("GET", "/health")
        report = await diagnose_http(
            "https://remote.invalid",
            tls_ca_file="secret-ca",
            tls_cert_file="secret-cert",
            tls_key_file="secret-key",
        )
        self.assertFalse(report["ok"])
        self.assertNotIn("secret", json.dumps(report))

    async def test_pre_stopped_worker_does_not_start_and_close_errors_still_remove_signals(
        self,
    ):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker.serve_forever = AsyncMock()
        worker.close = AsyncMock()
        stopped = asyncio.Event()
        stopped.set()
        await _serve(worker, stopped=stopped)
        worker.serve_forever.assert_not_awaited()
        worker.close = AsyncMock(side_effect=ConnectionLost("close failed"))
        loop = asyncio.get_running_loop()
        with (
            patch.object(loop, "add_signal_handler", side_effect=lambda sig, fn: fn()),
            patch.object(loop, "remove_signal_handler") as remove,
        ):
            with self.assertRaises(ConnectionLost):
                await _serve(worker)
            self.assertEqual(remove.call_count, 2)

    async def test_doctor_rejects_malformed_and_non_ready_health_responses(self):
        for reply in [
            {"type": "health"},
            {"type": "health", "state": "failed"},
            {"type": "health", "state": {"private": "value"}},
        ]:
            with patch.object(
                TayHTTP, "_request", new_callable=AsyncMock, return_value=reply
            ):
                report = await diagnose_http("http://127.0.0.1:8080")
                self.assertFalse(report["ok"])
                self.assertEqual(report["error"], "invalid_health_response")
                self.assertNotIn("private", json.dumps(report))


class CLIEntryTests(unittest.TestCase):
    def test_legacy_command_and_worker_subcommand_share_runner(self):
        with (
            patch("tay.__main__._instance", return_value=MagicMock()) as instance,
            patch(
                "tay.__main__.asyncio.run",
                side_effect=lambda coroutine: coroutine.close(),
            ),
        ):
            self.assertEqual(main(["app:worker"]), 0)
            self.assertEqual(main(["worker", "app:worker"]), 0)
            self.assertEqual(instance.call_count, 2)

    def test_doctor_failure_has_nonzero_exit_and_machine_readable_output(self):
        with (
            contextlib.redirect_stdout(io.StringIO()) as output,
            patch(
                "tay.__main__.diagnose_socket",
                new_callable=AsyncMock,
                return_value={"ok": False, "error": "missing"},
            ),
        ):
            self.assertEqual(main(["doctor", "--json"]), 1)
        self.assertFalse(json.loads(output.getvalue())["ok"])
