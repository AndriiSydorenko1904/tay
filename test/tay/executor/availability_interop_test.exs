defmodule Tay.Executor.AvailabilityInteropTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, ExecutionClock, ExecutionHelpers, NativeHelpers}
  @moduletag capture_log: true

  for transport <- [:socket, :http] do
    @transport transport
    test "#{transport} workers report unavailability and new work wakes deferred jobs" do
      Process.flag(:trap_exit, true)
      ExecutionHelpers.install()
      path = NativeHelpers.path()
      ExecutionHelpers.initialize(path)

      socket =
        Path.join(Path.dirname(path), "availability-#{System.unique_integer([:positive])}.sock")

      {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
      {:ok, port} = :inet.port(listener)
      :gen_tcp.close(listener)

      on_exit(fn ->
        File.rm(socket)
        File.rm_rf!(path)
      end)

      {:ok, root} =
        ExecutionHelpers.start(path, __MODULE__,
          workers: %{},
          executor_socket: socket,
          http_port: port,
          test_clock: ExecutionClock,
          compaction: [terminal_retention: :infinity]
        )

      Process.unlink(root)
      on_exit(fn -> EngineHelpers.stop(root) end)
      assert EngineHelpers.eventually(fn -> File.exists?(socket) end)

      script = """
      import asyncio, contextlib, sys
      sys.path.insert(0, #{inspect(Path.expand("clients/python"))})
      from tay import Tay, TayHTTP, TayHTTPWorker, DependencyUnavailable

      async def main():
          offline = True
          executions = []
          if sys.argv[1] == "socket":
              worker = Tay(socket_path=sys.argv[2], mode="embedded")
              producer = worker
          else:
              worker = TayHTTPWorker(sys.argv[3])
              producer = TayHTTP(sys.argv[3])

          @worker.task(name="availability.send", retries="infinity",
                       availability_key="reports-api", durability="persistent")
          def send_report(value):
              executions.append(value)
              if offline:
                  raise DependencyUnavailable("network unavailable")
              return {"sent": value}

          runner = None
          if sys.argv[1] == "socket":
              await worker.start()
          else:
              await worker.register()
              runner = asyncio.create_task(worker.serve_forever())
          try:
              first = await producer.enqueue("availability.send", {"value": 1},
                  retries="infinity", availability_key="reports-api")
              for _ in range(200):
                  if await first.status() == "retryable":
                      break
                  await asyncio.sleep(0.01)
              else:
                  raise AssertionError("task never became retryable")
              assert executions == [1], executions
              offline = False
              second = await producer.enqueue("availability.send", {"value": 2},
                  availability_key="reports-api")
              for _ in range(300):
                  if await first.status() == "completed" and await second.status() == "completed":
                      break
                  await asyncio.sleep(0.01)
              else:
                  raise AssertionError("new insertion did not wake deferred job")
              assert await first.result() == {"sent": 1}
              assert await second.result() == {"sent": 2}
              assert executions.count(1) == 2
          finally:
              if runner:
                  runner.cancel()
                  with contextlib.suppress(asyncio.CancelledError):
                      await runner
              await worker.close()
              if producer is not worker:
                  await producer.close()

      asyncio.run(main())
      """

      {output, status} =
        System.cmd(
          NativeHelpers.python!(),
          ["-c", script, Atom.to_string(@transport), socket, "http://127.0.0.1:#{port}"],
          stderr_to_stdout: true
        )

      assert {output, status} == {"", 0}
      assert Tay.status(name: __MODULE__).availability["reports-api"]["status"] == "available"
      assert {:ok, _} = Tay.compact(name: __MODULE__, terminal_retention: {:hours, 0})
      assert :ok = Tay.restart(name: __MODULE__)
      assert Tay.status(name: __MODULE__).availability["reports-api"]["status"] == "available"
    end
  end
end
