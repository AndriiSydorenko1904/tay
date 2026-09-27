defmodule Tay.Standalone.HealthTest do
  use ExUnit.Case, async: false

  test "HTTP-only health check probes HTTP instead of requiring a Unix socket" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)

    keys = ["TAY_DATA_DIR", "TAY_SOCKET_PATH", "TAY_HTTP_PORT", "TAY_HTTP_IP"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    System.put_env("TAY_DATA_DIR", "/tmp/tay-health-unused")
    System.put_env("TAY_SOCKET_PATH", "off")
    System.put_env("TAY_HTTP_PORT", Integer.to_string(port))
    System.put_env("TAY_HTTP_IP", "127.0.0.1")

    on_exit(fn ->
      :gen_tcp.close(listener)

      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    assert :ok = Tay.Standalone.Health.check!(%{state: :ready})

    assert_raise RuntimeError, ~r/not ready/, fn ->
      Tay.Standalone.Health.check!(%{state: :recovering})
    end
  end
end
