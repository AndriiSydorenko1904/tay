import asyncio
import sys

from tay import JobHandle, Tay


async def main() -> None:
    client = Tay(mode="client", client_id="standalone-smoke-client")
    await client.start()
    try:
        if len(sys.argv) == 1:
            job = await client.enqueue(
                "example.echo.v1",
                {"message": "durable"},
                submission_id="standalone-smoke-job",
            )
            result = await job.result()
            if result != {"message": "durable"}:
                raise RuntimeError(f"unexpected result: {result!r}")
            print(job.id)
        else:
            status = await JobHandle(sys.argv[1], client).status()
            if status != "completed":
                raise RuntimeError(f"job was not recovered as completed: {status!r}")
            print(status)
    finally:
        await client.close()


asyncio.run(main())
