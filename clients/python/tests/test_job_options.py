from __future__ import annotations

import pathlib
import sys
import unittest
from types import MappingProxyType
from unittest.mock import AsyncMock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tay import Tay, TayHTTP, TayHTTPWorker, ValidationError


class JobOptionsTests(unittest.IsolatedAsyncioTestCase):
    def producers(self):
        clients = [
            Tay(socket_path="/tmp/tay-options-test.sock"),
            TayHTTP("http://127.0.0.1:8080"),
        ]
        for client in clients:
            client._request = AsyncMock(return_value={"job_id": "j"})
        return clients

    async def test_invalid_option_types_are_rejected_before_a_request(self):
        for client in self.producers():
            for invalid in [[], ["x"], [("retries", 1)], 0, False, "", set()]:
                with self.subTest(client=type(client).__name__, invalid=invalid):
                    with self.assertRaises(ValidationError):
                        await client.enqueue("test.task", {}, options=invalid)
                    client._request.assert_not_awaited()

    async def test_arguments_are_objects_even_when_empty_or_false(self):
        for client in self.producers():
            for invalid in [[], [1], 0, False, ""]:
                with self.subTest(client=type(client).__name__, invalid=invalid):
                    with self.assertRaises(ValidationError):
                        await client.enqueue("test.task", invalid)
                    client._request.assert_not_awaited()

    async def test_payloads_are_identical_and_do_not_mutate_caller_mappings(self):
        payloads = []
        for client in self.producers():
            options = MappingProxyType({"queue": "default", "priority": 0})
            args = MappingProxyType({"n": 1})
            await client.enqueue(
                "test.task",
                args,
                options=options,
                retries=0,
                delay=0,
                durability="volatile",
            )
            payloads.append(client._request.await_args.args[-1])
            self.assertEqual(dict(options), {"queue": "default", "priority": 0})
            self.assertEqual(dict(args), {"n": 1})
        self.assertEqual(payloads[0], payloads[1])
        self.assertEqual(payloads[0]["options"]["durability"], "volatile")

    async def test_explicit_duplicates_are_rejected_consistently(self):
        for client in self.producers():
            for keywords in [
                {"options": {"retries": 1}, "retries": 2},
                {"options": {"durability": "volatile"}, "durability": "persistent"},
                {"options": {"delay": None}, "delay": 0},
            ]:
                with self.subTest(client=type(client).__name__, keywords=keywords):
                    with self.assertRaisesRegex(
                        ValidationError, "option supplied twice"
                    ):
                        await client.enqueue("test.task", {}, **keywords)
                    client._request.assert_not_awaited()

    async def test_unhashable_durability_and_backoff_are_validation_errors(self):
        for client in self.producers():
            for key in ["durability", "backoff"]:
                for value in [[], {}, set()]:
                    with self.subTest(
                        client=type(client).__name__, key=key, value=value
                    ):
                        with self.assertRaises(ValidationError):
                            await client.enqueue("test.task", {}, options={key: value})
                        client._request.assert_not_awaited()

    async def test_absent_arguments_and_options_use_the_same_empty_payload(self):
        for client in self.producers():
            await client.enqueue("test.task")
            self.assertEqual(
                client._request.await_args.args[-1],
                {"task": "test.task", "args": {}, "options": {}},
            )

    async def test_decorated_tasks_reject_duplicate_submission_options(self):
        for owner in [
            Tay(socket_path="/tmp/tay-task-options.sock"),
            TayHTTPWorker("http://127.0.0.1:8080"),
        ]:
            owner._request = AsyncMock(return_value={"job_id": "j"})

            @owner.task(retries=3)
            def work(value):
                return value

            with self.assertRaisesRegex(
                ValidationError, "option supplied twice: retries"
            ):
                await work.enqueue(1, options={"retries": 1}, retries=2)
            owner._request.assert_not_awaited()
            await work.enqueue(1, retries=0)
            self.assertEqual(
                owner._request.await_args.args[-1]["options"]["retries"], 0
            )

    async def test_task_parameter_wins_over_a_submission_option_with_the_same_name(
        self,
    ):
        owner = self.producers()[0]

        @owner.task
        def work(retries):
            return retries

        await work.enqueue(retries=2, options={"retries": 1})
        payload = owner._request.await_args.args[-1]
        self.assertEqual(payload["args"], {"retries": 2})
        self.assertEqual(payload["options"], {"retries": 1})

    async def test_schedule_and_every_reject_invalid_false_like_arguments(self):
        client = self.producers()[0]
        for invalid in [[], 0, False, ""]:
            for operation in ["schedule", "every"]:
                for argument in ["args", "kwargs"]:
                    with self.subTest(
                        operation=operation, argument=argument, invalid=invalid
                    ):
                        options = (
                            {"cron": "* * * * *"}
                            if operation == "schedule"
                            else {"seconds": 1}
                        )
                        with self.assertRaises(ValidationError):
                            await getattr(client, operation)(
                                "test.task", **options, **{argument: invalid}
                            )
                        client._request.assert_not_awaited()

    async def test_invalid_enum_containers_are_not_leaked_as_type_errors(self):
        for value in [[], {}]:
            with self.assertRaises(ValidationError):
                Tay(mode=value)
            for owner in [
                Tay(socket_path="/tmp/tay-invalid-enum.sock"),
                TayHTTPWorker("http://127.0.0.1:8080"),
            ]:
                with self.assertRaises(ValidationError):
                    owner.task(durability=value)
            client = self.producers()[0]
            for field in ["overlap", "catch_up"]:
                with self.assertRaises(ValidationError):
                    await client.every("test.task", seconds=1, **{field: value})
                client._request.assert_not_awaited()
