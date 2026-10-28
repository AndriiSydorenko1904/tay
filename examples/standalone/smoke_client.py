import asyncio
import os
import sys

from tay import JobHandle, Tay


async def main() -> None:
    client = Tay(mode="client", client_id="standalone-smoke-client")
    if "TAY_SOCKET_PATH" in os.environ:
        raise RuntimeError("socket smoke must exercise discovery without TAY_SOCKET_PATH")
    if client.socket_path != "/run/tay/tay.sock":
        raise RuntimeError(f"unexpected discovered path: {client.socket_path!r}")
    await client.start()
    try:
        if len(sys.argv) == 1 or sys.argv[1] == "--enqueue":
            job = await client.enqueue(
                "example.echo.v1",
                {"message": "durable"},
                submission_id=sys.argv[2] if len(sys.argv) > 2 else "standalone-smoke-job",
            )
            while await job.status() != "completed":
                await asyncio.sleep(0.05)
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


asyncio.run(asyncio.wait_for(main(), timeout=40))
