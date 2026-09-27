defmodule Tay.Standalone.HealthTest do
  use ExUnit.Case, async: false
  @moduletag skip: :os.type() != {:unix, :linux}

  test "HTTP-only runtime health check does not require a Unix socket" do
    Process.flag(:trap_exit, true)
    path = Path.join(System.tmp_dir!(), "tay-http-health-#{System.unique_integer([:positive])}")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    keys = ["TAY_DATA_DIR", "TAY_SOCKET_PATH", "TAY_HTTP_PORT", "TAY_HTTP_IP"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    System.put_env("TAY_DATA_DIR", path)
    System.put_env("TAY_SOCKET_PATH", "off")
    System.put_env("TAY_HTTP_PORT", Integer.to_string(port))
    System.put_env("TAY_HTTP_IP", "127.0.0.1")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(path)
    end)

    assert {:ok, runtime} =
             Tay.start_link(
               data_dir: path,
               initialize: :if_missing,
               durability: :sync,
               validated_filesystem: true,
               workers: %{},
               queues: [default: 10],
               executor_socket: nil,
               http_port: port
             )

    on_exit(fn ->
      try do
        if Process.alive?(runtime), do: Supervisor.stop(runtime)
      catch
        :exit, _ -> :ok
      end
    end)

    assert eventually(fn ->
             try do
               Tay.Standalone.Health.check!() == :ok
             rescue
               _ -> false
             end
           end)
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
