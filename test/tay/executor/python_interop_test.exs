defmodule Tay.Executor.PythonInteropTest do
  use ExUnit.Case, async: false

  alias Tay.Executor.SocketPath
  alias Tay.Test.{EngineHelpers, ExecutionHelpers, NativeHelpers}

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    socket = Path.join(Path.dirname(path), "executor-#{System.unique_integer([:positive])}.sock")
    ExecutionHelpers.initialize(path)

    on_exit(fn ->
      File.rm(socket)
      File.rm_rf!(path)
    end)

    %{path: path, socket: socket}
  end

  test "a stdlib Python embedded client handshakes, executes, and returns JSON", %{
    path: path,
    socket: socket
  } do
    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               executor_socket: socket,
               executor_max_connections: 2,
               execution_wake_ms: 5
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert ExecutionHelpers.eventually(fn -> File.exists?(socket) end)

    script = """
    import asyncio
    import json
    import sys

    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import ServerError, Tay

    async def main():
        client = Tay(mode="embedded", socket_path=sys.argv[1], client_id="python-interop")
        executions = []

        @client.task(name="python.interop.v1")
        def add(left, right):
            executions.append((left, right))
            return {"sum": left + right}

        await client.start()
        try:
            schedule = await client.every(
                "python.interop.v1", seconds=0.05, kwargs={"left": 1, "right": 2}
            )
            assert schedule.id
            for _ in range(100):
                if executions:
                    break
                await asyncio.sleep(0.01)
            assert executions
            cancelled = await schedule.cancel()
            assert cancelled["cancelled_at"] is not None

            job = await client.enqueue(
                "python.interop.v1",
                {"left": 2, "right": 5},
                submission_id="python-interop-submission",
            )
            statuses = []
            for _ in range(100):
                current = await job.status()
                statuses.append(current)
                if current == "completed":
                    print(json.dumps(await job.result(), sort_keys=True))
                    return
                await asyncio.sleep(0.02)
            raise RuntimeError(f"job did not complete: {statuses!r}")
        finally:
            await client.close()

    asyncio.run(main())
    """

    python =
      if File.exists?("/opt/homebrew/bin/python3"),
        do: "/opt/homebrew/bin/python3",
        else: System.find_executable("python3")

    {output, status} =
      System.cmd(python, ["-c", script, socket],
        stderr_to_stdout: true,
        env: [
          {"PYTHONPYCACHEPREFIX", "/private/tmp/tay-python-cache"}
        ]
      )

    assert {"{\"sum\": 7}\n", 0} == {output, status}
  end

  test "a default Tay() client discovers the automatic listener without configuration", %{
    path: path
  } do
    assert {:ok, %{path: socket}} = SocketPath.resolve()

    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               executor_socket: :auto,
               executor_max_connections: 2,
               execution_wake_ms: 5
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert ExecutionHelpers.eventually(fn -> File.exists?(socket) end)

    script = """
    import asyncio
    import json
    import sys

    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import Tay

    async def main():
        client = Tay()

        @client.task(name="python.discovery.v1")
        def discovered():
            return {"connected": True}

        await client.start()
        try:
            job = await client.enqueue("python.discovery.v1", {})
            for _ in range(100):
                if await job.status() == "completed":
                    print(json.dumps(await job.result(), sort_keys=True))
                    return
                await asyncio.sleep(0.02)
            raise RuntimeError("automatically discovered listener did not run the job")
        finally:
            await client.close()

    asyncio.run(main())
    """

    python =
      if File.exists?("/opt/homebrew/bin/python3"),
        do: "/opt/homebrew/bin/python3",
        else: System.find_executable("python3")

    assert {"{\"connected\": true}\n", 0} =
             System.cmd(python, ["-c", script],
               stderr_to_stdout: true,
               env: [{"PYTHONPYCACHEPREFIX", "/private/tmp/tay-python-cache"}]
             )
  end

  test "a Python producer receives the exact admission capacity reason", %{
    path: path,
    socket: socket
  } do
    parent = self()

    hook = fn point ->
      if point == :pre_reply do
        send(parent, {:enqueue_held, self()})

        receive do
          :continue -> :ok
        end
      end
    end

    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               executor_socket: socket,
               executor_max_connections: 2,
               client_slots: 1,
               test_hook: hook
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert ExecutionHelpers.eventually(fn -> File.exists?(socket) end)

    script = """
    import asyncio
    import json
    import sys

    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import ServerError, Tay

    async def main():
        client = Tay(mode="client", socket_path=sys.argv[1], request_timeout=2)
        await client.start()
        first = asyncio.create_task(client.enqueue("tests.capacity.v1", {"n": 1}))
        await asyncio.sleep(0.05)
        try:
            await client.enqueue("tests.capacity.v1", {"n": 2})
        except ServerError as error:
            print(json.dumps({"code": error.code, "reason": error.details["reason"]}, sort_keys=True))
        else:
            raise RuntimeError("second enqueue unexpectedly passed admission")
        finally:
            first.cancel()
            await asyncio.gather(first, return_exceptions=True)
            await client.close()

    asyncio.run(main())
    """

    python =
      if File.exists?("/opt/homebrew/bin/python3"),
        do: "/opt/homebrew/bin/python3",
        else: System.find_executable("python3")

    command =
      Task.async(fn ->
        System.cmd(python, ["-c", script, socket],
          stderr_to_stdout: true,
          env: [{"PYTHONPYCACHEPREFIX", "/private/tmp/tay-python-cache"}]
        )
      end)

    assert_receive {:enqueue_held, engine}, 2_000

    assert {"{\"code\": \"capacity\", \"reason\": \"client_slots\"}\n", 0} =
             Task.await(command, 5_000)

    send(engine, :continue)
  end

  test "an absent capability stays pending without blocking a later advertised task", %{
    path: path,
    socket: socket
  } do
    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               executor_socket: socket,
               executor_max_connections: 2,
               execution_wake_ms: 5
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert {:ok, unavailable} = Tay.enqueue("python.unavailable.v1", %{}, name: @name)
    assert {:ok, runnable} = Tay.enqueue("python.ready.v1", %{}, name: @name)
    assert {:ok, %{state: :available, attempt: 0}} = Tay.get_job(unavailable.id, name: @name)

    script = """
    import asyncio
    import json
    import sys

    sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
    from tay import Tay

    async def main():
        client = Tay(mode="embedded", socket_path=sys.argv[1], client_id="python-capability")

        @client.task(name="python.ready.v1")
        def ready():
            return {"ran": True}

        await client.start()
        try:
            for _ in range(100):
                reply = await client._request("status", {"job_id": sys.argv[2]})
                if reply["status"] == "completed":
                    result = await client._request("result", {"job_id": sys.argv[2]})
                    print(json.dumps(result["result"], sort_keys=True))
                    return
                await asyncio.sleep(0.02)
            raise RuntimeError("runnable job did not complete")
        finally:
            await client.close()

    asyncio.run(main())
    """

    python =
      if File.exists?("/opt/homebrew/bin/python3"),
        do: "/opt/homebrew/bin/python3",
        else: System.find_executable("python3")

    assert {"{\"ran\": true}\n", 0} =
             System.cmd(python, ["-c", script, socket, runnable.id],
               stderr_to_stdout: true,
               env: [{"PYTHONPYCACHEPREFIX", "/private/tmp/tay-python-cache"}]
             )

    assert {:ok, %{state: :available, attempt: 0}} = Tay.get_job(unavailable.id, name: @name)
  end
end
