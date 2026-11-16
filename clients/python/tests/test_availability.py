from __future__ import annotations

import pathlib
import sys
import unittest
from unittest.mock import AsyncMock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import DependencyUnavailable, Tay, TayHTTP, TayHTTPWorker, ValidationError
from tay.execution import bounded_error, error_details


class AvailabilityTests(unittest.IsolatedAsyncioTestCase):
    async def test_decorator_defaults_and_overrides_on_both_transports(self):
        for owner in [
            Tay(socket_path="/tmp/tay-availability.sock"),
            TayHTTPWorker("http://127.0.0.1:8080"),
        ]:

            @owner.task(name="send", availability_key="reports-api", retries="infinity")
            def send(value):
                return value

            producer = owner if isinstance(owner, Tay) else TayHTTP()
            producer._request = AsyncMock(return_value={"job_id": "job"})
            if producer is owner:
                await send.enqueue(value=1)
                options = producer._request.await_args.args[-1]["options"]
                self.assertEqual(options["availability_key"], "reports-api")
                self.assertEqual(options["retries"], "infinity")
            self.assertEqual(send.config.execution_options()["retries"], "infinity")

    async def test_volatile_dependency_is_rejected(self):
        client = Tay(socket_path="/tmp/tay-availability.sock")
        client._request = AsyncMock()
        with self.assertRaises(ValidationError):
            await client.enqueue(
                "send", {}, availability_key="api", durability="volatile"
            )
        client._request.assert_not_awaited()

    def test_exception_subclasses_preserve_wire_marker(self):
        class MyOutage(DependencyUnavailable):
            pass

        error = MyOutage("offline")
        self.assertEqual(error_details(error)["type"], "DependencyUnavailable")
        self.assertEqual(
            bounded_error(error, max_bytes=256, include_traceback=True)["type"],
            "DependencyUnavailable",
        )
