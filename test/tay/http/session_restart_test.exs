defmodule Tay.HTTP.SessionRestartTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{ExecutionHelpers, NativeHelpers}

  @tag timeout: 60_000
  test "real HTTP worker preserves capacity and fences old completion across Tay restart" do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    flags = path <> "-control"
    ExecutionHelpers.initialize(path)
    File.mkdir_p!(flags)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {:ok, root} =
             ExecutionHelpers.start(path, __MODULE__,
               workers: %{},
               executor_socket: nil,
               http_port: port,
               execution_wake_ms: 5
             )

    Process.unlink(root)

    on_exit(fn ->
      File.write!(Path.join(flags, "release"), "go")
      ExecutionHelpers.stop(root)
      File.rm_rf!(path)
      File.rm_rf!(flags)
    end)

    script = Path.expand("test/support/http_restart_worker.py")

    worker =
      Task.async(fn ->
        System.cmd(NativeHelpers.python!(), [script, "http://127.0.0.1:#{port}", flags],
          stderr_to_stdout: true
        )
      end)

    assert ExecutionHelpers.eventually(fn -> File.exists?(Path.join(flags, "entered")) end, 1000)
    assert :ok = Tay.restart(name: __MODULE__, force: true, timeout: 15_000)
    File.write!(Path.join(flags, "restarted"), "ready")
    assert {output, 0} = Task.await(worker, 30_000)

    assert Jason.decode!(String.trim(output)) == %{
             "max_concurrency" => 1,
             "new_result" => "new",
             "old_completion_sent" => false
           }
  end
end
