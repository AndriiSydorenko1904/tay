"""Live HTTP worker/session restart qualification, invoked by ExUnit."""

from __future__ import annotations

import asyncio
import contextlib
import json
import pathlib
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "clients/python"))
from tay import TayHTTP, TayHTTPWorker
from tay.__main__ import _serve
from tay.doctor import diagnose_http


async def until(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise TimeoutError("restart worker coordination deadline")
        await asyncio.sleep(0.01)


async def main(base, directory):
    flags = pathlib.Path(directory)
    worker = TayHTTPWorker(base, capacity=1)
    lock = threading.Lock()
    active = 0
    peak = 0
    events = []
    original_request = worker._request

    async def request(method, path, body=None, **kwargs):
        if path in ["/workers/started", "/workers/complete"]:
            events.append((path, body, kwargs.get("headers", {}).get("Authorization")))
        return await original_request(method, path, body, **kwargs)

    worker._request = request

    @worker.task(name="tests.restart-session.v1")
    def work(label):
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
        try:
            if label == "old":
                (flags / "entered").write_text("ready")
                deadline = time.monotonic() + 20
                while not (flags / "release").exists():
                    if time.monotonic() >= deadline:
                        raise TimeoutError("sync worker release deadline")
                    time.sleep(0.01)
            return label
        finally:
            with lock:
                active -= 1

    serving = asyncio.create_task(_serve(worker))
    try:
        async with TayHTTP(base) as producer:
            await until(lambda: worker._token is not None)
            await producer.enqueue("tests.restart-session.v1", {"label": "old"})
            await until(lambda: (flags / "entered").exists())
            old_execution = events[0][1]["execution_id"]
            await until(lambda: (flags / "restarted").exists())
            await until(lambda: worker._token is None)
            new = await producer.enqueue("tests.restart-session.v1", {"label": "new"})
            assert await new.status() == "available"
            assert worker._token is None and len(worker._executions) == 1
            (flags / "release").write_text("go")
            assert await new.wait_result(timeout=20, poll_interval=0.02) == "new"
            assert (await diagnose_http(base))["ok"]
            assert peak == 1
            assert not any(
                path == "/workers/complete" and body["execution_id"] == old_execution
                for path, body, _ in events
            )
            print(
                json.dumps(
                    {
                        "max_concurrency": peak,
                        "new_result": "new",
                        "old_completion_sent": False,
                    }
                )
            )
    finally:
        (flags / "release").write_text("go")
        serving.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await serving
        await worker.close()


asyncio.run(main(*sys.argv[1:]))
