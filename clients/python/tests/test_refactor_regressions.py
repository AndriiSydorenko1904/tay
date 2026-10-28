from __future__ import annotations

import asyncio
import pathlib
import sys
import unittest
from functools import partial
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import ConnectionLost, Tay, TayHTTP, TayHTTPWorker
from tay.errors import ServerError, TaskRegistrationError, ValidationError
from tay.execution import bounded_error
from tay.protocol import json_bytes


class RefactorRegressionTests(unittest.IsolatedAsyncioTestCase):
    def owners(self):
        return [
            Tay(socket_path="/tmp/tay-validation.sock"),
            TayHTTPWorker("http://127.0.0.1:8080"),
        ]

    async def test_both_transports_reject_invalid_retries_before_submission(self):
        for owner in self.owners():
            for value in [-1, 65_535, True, 1.5, "1"]:
                with self.subTest(owner=type(owner).__name__, value=value):
                    with self.assertRaises(ValidationError):
                        owner.task(lambda: None, name="task", retries=value)
                    owner._request = AsyncMock()
                    with self.assertRaises(ValidationError):
                        await owner.enqueue("task", options={"retries": value})
                    owner._request.assert_not_awaited()
            declared = owner.task(lambda: None, name="valid", retries=65_534)
            self.assertEqual(declared.config.retries, 65_534)

    async def test_registration_has_shared_identity_and_collision_rules(self):
        for owner in self.owners():
            fn = partial(int, "2")
            with self.assertRaises(TaskRegistrationError):
                owner.task(fn)
            task = owner.task(fn, name="partial")
            self.assertIs(task, owner.task(fn, name="partial"))
            self.assertEqual(task(), 2)
            with self.assertRaises(TaskRegistrationError):
                owner.task(lambda: None, name="partial")
            with self.assertRaises(ValidationError):
                owner.task(lambda: None, name="")

    async def test_transport_limits_require_finite_positive_numbers(self):
        for invalid in [
            float("nan"),
            float("inf"),
            -float("inf"),
            0,
            -1,
            True,
            "1",
            None,
            10**1000,
        ]:
            for key in [
                "request_timeout",
                "connect_timeout",
                "reconnect_initial_delay",
                "reconnect_max_delay",
            ]:
                with (
                    self.subTest(key=key, invalid=str(invalid)),
                    self.assertRaises(ValidationError),
                ):
                    Tay(socket_path="/tmp/tay-validation.sock", **{key: invalid})
            with self.assertRaises(ValidationError):
                TayHTTP(request_timeout=invalid)
            with self.assertRaises(ValidationError):
                TayHTTPWorker("http://127.0.0.1:8080", request_timeout=invalid)

    async def test_worker_and_client_ids_share_utf8_limits(self):
        for invalid in ["", False, 1, "\x00", "x" * 129, "\ud800"]:
            with self.subTest(invalid=repr(invalid)):
                with self.assertRaises(ValidationError):
                    Tay(socket_path="/tmp/tay-validation.sock", client_id=invalid)
                with self.assertRaises(ValidationError):
                    TayHTTPWorker("http://127.0.0.1:8080", runtime_id=invalid)

    async def test_arbitrary_task_exceptions_always_produce_bounded_json(self):
        class BrokenMessage(Exception):
            def __str__(self):
                raise RuntimeError("broken formatter")

        for error in [
            ValueError("\ud800" * 10_000),
            BrokenMessage(),
            ValueError("ї" * 10_000),
        ]:
            for trace in [False, True]:
                for limit in [2, 128, 8192]:
                    details = bounded_error(
                        error, max_bytes=limit, include_traceback=trace
                    )
                    self.assertLessEqual(len(json_bytes(details)), limit)
        # Verify the transport reports FAILED instead of losing the execution.
        for owner in self.owners():

            def fail():
                raise BrokenMessage()

            task = owner.task(fail, name="failure")
            if isinstance(owner, Tay):
                owner._send_event = AsyncMock()
                await owner._run_execution("r", "e", "j", task, {}, True)
                self.assertEqual(owner._send_event.await_args.args[0], "failed")
                json_bytes(owner._send_event.await_args.args[1])
            else:
                owner._worker_request = AsyncMock(return_value={})
                await owner._execute(
                    {
                        "reservation_id": "r",
                        "execution_id": "e",
                        "task": "failure",
                        "args": {},
                    }
                )
                completion = owner._worker_request.await_args.args[2]
                self.assertEqual(completion["outcome"], "failure")
                json_bytes(completion)

    async def test_registration_recovers_from_outages_before_and_after_session_loss(
        self,
    ):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        attempts = 0

        async def register():
            nonlocal attempts
            attempts += 1
            if attempts in [1, 3]:
                raise ConnectionLost("temporary registration outage")
            worker._token = "t" * 43

        async def claim(*args):
            if attempts == 2:
                worker._token = None
                raise ServerError("lost session", code="unknown_worker")
            worker._closing = True
            return {}

        worker.register = AsyncMock(side_effect=register)
        worker._worker_request = AsyncMock(side_effect=claim)
        with patch("tay.http.asyncio.sleep", new_callable=AsyncMock) as sleep:
            await asyncio.wait_for(worker._run_loop(), 1)
        self.assertEqual(attempts, 4)
        self.assertEqual(sleep.await_count, 2)
        self.assertEqual(worker._worker_request.await_count, 2)

    async def test_closing_interrupts_registration_retry(self):
        worker = TayHTTPWorker("http://127.0.0.1:8080")
        worker.register = AsyncMock(side_effect=ConnectionLost("down"))
        worker._worker_request = AsyncMock()
        serving = asyncio.create_task(worker.serve_forever())
        while not worker.register.await_count:
            await asyncio.sleep(0)
        await worker.close()
        await asyncio.gather(serving, return_exceptions=True)
        self.assertTrue(serving.done())
        worker._worker_request.assert_not_awaited()
