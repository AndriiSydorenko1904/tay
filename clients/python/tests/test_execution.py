from __future__ import annotations

import asyncio
import pathlib
import sys
import threading
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import tay.execution as execution_module
import tay.protocol as protocol_module
from tay import ConnectionLost, Tay, TayHTTPWorker
from tay.errors import ResultTooLarge, ValidationError
from tay.execution import bounded_error, cancel_async_execution, error_details, run_task
from tay.protocol import encoded_json_size


class TaskExecutionTests(unittest.IsolatedAsyncioTestCase):
    def declare(self, function):
        return Tay(socket_path="/tmp/tay-runner-test.sock").task(function)

    async def test_sync_calls_run_in_a_thread_and_async_calls_on_the_loop(self):
        loop_thread = threading.get_ident()

        def sync():
            return threading.get_ident()

        async def async_task():
            return threading.get_ident()

        sync_result = await run_task(
            self.declare(sync), {}, synchronous=True, max_result_bytes=1024
        )
        async_result = await run_task(
            self.declare(async_task), {}, synchronous=False, max_result_bytes=1024
        )
        self.assertNotEqual(sync_result, loop_thread)
        self.assertEqual(async_result, loop_thread)

    async def test_sync_function_may_return_an_awaitable(self):
        async def answer():
            return {"answer": 42}

        def sync():
            return answer()

        self.assertEqual(
            await run_task(
                self.declare(sync), {}, synchronous=True, max_result_bytes=1024
            ),
            {"answer": 42},
        )

    async def test_result_limits_use_utf8_bytes_and_preserve_transport_errors(self):
        def value():
            return "її"

        task = self.declare(value)
        self.assertEqual(
            await run_task(task, {}, synchronous=True, max_result_bytes=6), "її"
        )
        with self.assertRaises(ResultTooLarge):
            await run_task(task, {}, synchronous=True, max_result_bytes=5)
        with self.assertRaisesRegex(ValidationError, "HTTP limit 5"):
            await run_task(
                task,
                {},
                synchronous=True,
                max_result_bytes=5,
                size_error=lambda _, limit: ValidationError(f"HTTP limit {limit}"),
            )

    async def test_only_async_executions_are_cancelled(self):
        task = asyncio.create_task(asyncio.sleep(60))
        cancel_async_execution(task, True)
        self.assertEqual(task.cancelling(), 0)
        cancel_async_execution(task, False)
        with self.assertRaises(asyncio.CancelledError):
            await task

    async def test_cancellation_propagates_without_becoming_a_task_error(self):
        started = asyncio.Event()

        async def wait():
            started.set()
            await asyncio.Event().wait()

        running = asyncio.create_task(
            run_task(self.declare(wait), {}, synchronous=False, max_result_bytes=1024)
        )
        await started.wait()
        running.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await running

    async def test_error_limits_preserve_each_transport_policy(self):
        error = ValueError("ї" * 1000)
        self.assertLessEqual(
            encoded_json_size(
                bounded_error(error, max_bytes=128, include_traceback=True)
            ),
            128,
        )
        self.assertEqual(
            error_details(error, max_type_characters=5, max_message_characters=2),
            {"type": "Value", "message": "її"},
        )
        self.assertEqual(
            error_details(ValueError()), {"type": "ValueError", "message": ""}
        )


class ExecutionRegressionTests(unittest.IsolatedAsyncioTestCase):
    def client(self):
        return Tay(socket_path="/tmp/tay-review-test.sock")

    async def test_delivery_failure_does_not_report_a_successful_task_as_failed(self):
        client = self.client()

        @client.task
        def answer():
            return 42

        client._send_event = AsyncMock(
            side_effect=[None, ConnectionLost("delivery lost")]
        )
        with self.assertRaises(ConnectionLost):
            await client._run_execution("r", "e", "j", answer, {}, True)
        self.assertEqual(
            [call.args[0] for call in client._send_event.await_args_list],
            ["started", "succeeded"],
        )

    async def test_task_failure_still_reports_failed(self):
        client = self.client()

        @client.task
        def fail():
            raise ValueError("task failed")

        client._send_event = AsyncMock()
        await client._run_execution("r", "e", "j", fail, {}, True)
        self.assertEqual(client._send_event.await_args_list[-1].args[0], "failed")
        self.assertEqual(
            client._send_event.await_args_list[-1].args[1]["error"]["type"],
            "ValueError",
        )

    async def test_normalization_is_not_repeated_when_measuring_a_result(self):
        client = self.client()

        @client.task
        def answer():
            return 42

        with (
            patch.object(
                execution_module,
                "normalize_json",
                wraps=execution_module.normalize_json,
            ) as direct,
            patch.object(
                protocol_module, "normalize_json", wraps=protocol_module.normalize_json
            ) as nested,
        ):
            self.assertEqual(
                await run_task(answer, {}, synchronous=False, max_result_bytes=128), 42
            )
        self.assertEqual(direct.call_count, 1)
        self.assertEqual(nested.call_count, 0)

    async def test_error_budget_also_bounds_long_unicode_exception_class_names(self):
        error_type = type("Ї" * 200, (Exception,), {})
        for limit in [2, 32, 128, 256, 8192]:
            for with_traceback in [False, True]:
                result = bounded_error(
                    error_type("ї" * 1000),
                    max_bytes=limit,
                    include_traceback=with_traceback,
                )
                self.assertLessEqual(encoded_json_size(result), limit)
        with self.assertRaises(ValidationError):
            bounded_error(ValueError(), max_bytes=1, include_traceback=False)

    async def test_http_close_cancels_and_awaits_async_executions(self):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker._token = "registered-token"
        worker._request = AsyncMock()
        worker._worker_request = AsyncMock()
        started = asyncio.Event()

        @worker.task
        async def wait():
            started.set()
            await asyncio.Event().wait()

        task = asyncio.create_task(
            worker._execute(
                {
                    "task": wait.name,
                    "args": {},
                    "reservation_id": "r",
                    "execution_id": "e",
                }
            )
        )
        worker._executions["e"] = task
        worker._execution_is_sync["e"] = False
        await asyncio.wait_for(started.wait(), 1)
        await asyncio.wait_for(worker.close(), 1)
        self.assertTrue(task.cancelled())
        self.assertEqual(worker._executions, {})
        self.assertIsNone(worker._token)
        worker._request.assert_awaited_once()
        self.assertEqual(worker._worker_request.await_count, 1)  # started only
        await worker.close()
        worker._request.assert_awaited_once()

    async def test_concurrent_http_close_stops_the_claim_loop_without_deadlocking(self):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker._token = "registered-token"
        worker._request = AsyncMock()
        claiming = asyncio.Event()

        async def claim(*args, **kwargs):
            claiming.set()
            await asyncio.Event().wait()

        worker._worker_request = claim
        serving = asyncio.create_task(worker.serve_forever())
        await asyncio.wait_for(claiming.wait(), 1)
        await asyncio.wait_for(asyncio.gather(worker.close(), worker.close()), 1)
        self.assertTrue(serving.done())
        self.assertIsNone(worker._serve_task)
        worker._request.assert_awaited_once()

    async def test_http_close_detaches_sync_thread_without_a_late_completion(self):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker._worker_request = AsyncMock()
        entered, release, finished = (
            threading.Event(),
            threading.Event(),
            threading.Event(),
        )

        @worker.task
        def blocking():
            entered.set()
            release.wait(2)
            finished.set()
            return 42

        task = asyncio.create_task(
            worker._execute(
                {
                    "task": blocking.name,
                    "args": {},
                    "reservation_id": "r",
                    "execution_id": "e",
                }
            )
        )
        worker._executions["e"] = task
        worker._execution_is_sync["e"] = True
        try:
            self.assertTrue(await asyncio.to_thread(entered.wait, 1))
            await asyncio.wait_for(worker.close(), 1)
            self.assertTrue(task.cancelled())
            self.assertFalse(finished.is_set())
        finally:
            release.set()
            await asyncio.to_thread(finished.wait, 1)
        self.assertEqual(worker._worker_request.await_count, 1)


class AwaitableCancellationTests(unittest.IsolatedAsyncioTestCase):
    async def test_socket_sync_wrapper_becomes_cancellable_after_its_thread_returns(
        self,
    ):
        client = Tay(socket_path="/tmp/tay-phase-test.sock")
        client._send_event = AsyncMock()
        waiting = asyncio.Event()

        async def continuation():
            waiting.set()
            await asyncio.Event().wait()

        @client.task
        def wrapper():
            return continuation()

        task = asyncio.create_task(
            client._run_execution("r", "e", "j", wrapper, {}, True)
        )
        client._executions["e"] = task
        client._execution_is_sync["e"] = True
        try:
            await asyncio.wait_for(waiting.wait(), 1)
            self.assertFalse(client._execution_is_sync["e"])
            await client._cancel_execution({"execution_id": "e"})
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(task, 1)
            completion = client._send_event.await_args.args
            self.assertEqual(completion[0], "failed")
            self.assertTrue(completion[1]["error"]["cancelled"])
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def test_http_sync_wrapper_becomes_cancellable_after_its_thread_returns(self):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker._worker_request = AsyncMock()
        waiting = asyncio.Event()

        async def continuation():
            waiting.set()
            await asyncio.Event().wait()

        @worker.task
        def wrapper():
            return continuation()

        task = asyncio.create_task(
            worker._execute(
                {
                    "task": wrapper.name,
                    "args": {},
                    "reservation_id": "r",
                    "execution_id": "e",
                }
            )
        )
        worker._executions["e"] = task
        worker._execution_is_sync["e"] = True
        try:
            await asyncio.wait_for(waiting.wait(), 1)
            self.assertFalse(worker._execution_is_sync["e"])
            cancel_async_execution(task, worker._execution_is_sync["e"])
            await asyncio.wait_for(task, 1)
            completion = worker._worker_request.await_args.args
            self.assertEqual(completion[1], "/workers/complete")
            self.assertEqual(completion[2]["error"]["type"], "CancelledError")
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
