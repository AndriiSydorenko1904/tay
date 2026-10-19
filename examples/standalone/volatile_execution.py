import asyncio
import contextlib
import sys

from tay import Tay, TayHTTP, TayHTTPWorker


async def completed(job) -> None:
    for _ in range(300):
        if await job.status() == "completed":
            if await job.result() is not None:
                raise RuntimeError("noop returned a non-null result")
            return
        await asyncio.sleep(0.01)
    raise RuntimeError("volatile job did not complete")


async def socket_execution(socket_path: str) -> None:
    client = Tay(mode="embedded", socket_path=socket_path, client_id="docker-volatile-socket")

    @client.task(name="loadtest.noop.v1", durability="volatile")
    def noop():
        return None

    await client.start()
    try:
        await completed(await noop.enqueue())
        await completed(await noop.enqueue())
    finally:
        await client.close()


async def http_execution(base_url: str) -> None:
    worker = TayHTTPWorker(base_url, runtime_id="docker-volatile-http")

    @worker.task(name="loadtest.noop.v1", durability="volatile")
    def noop():
        return None

    runner = asyncio.create_task(worker.serve_forever())
    try:
        async with TayHTTP(base_url) as producer:
            await completed(
                await producer.enqueue("loadtest.noop.v1", {}, durability="volatile")
            )
            await completed(
                await producer.enqueue("loadtest.noop.v1", {}, durability="volatile")
            )
    finally:
        runner.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await runner
        await worker.close()


if len(sys.argv) != 3 or sys.argv[1] not in {"socket", "http"}:
    raise SystemExit("usage: volatile_execution.py socket PATH | http BASE_URL")

if sys.argv[1] == "socket":
    asyncio.run(socket_execution(sys.argv[2]))
else:
    asyncio.run(http_execution(sys.argv[2]))
