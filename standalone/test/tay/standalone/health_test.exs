defmodule Tay.Standalone.HealthTest do
  use ExUnit.Case, async: false

  test "HTTP-only health check probes HTTP instead of requiring a Unix socket" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listener)

    previous = Application.fetch_env(:tay_standalone, :environment)

    Application.put_env(:tay_standalone, :environment, %{
      "TAY_DATA_DIR" => "/tmp/tay-health-unused",
      "TAY_SOCKET_PATH" => "off",
      "TAY_HTTP_PORT" => Integer.to_string(port),
      "TAY_HTTP_IP" => "127.0.0.1"
    })

    on_exit(fn ->
      :gen_tcp.close(listener)

      case previous do
        {:ok, environment} -> Application.put_env(:tay_standalone, :environment, environment)
        :error -> Application.delete_env(:tay_standalone, :environment)
      end
    end)

    assert :ok = Tay.Standalone.Health.check!(%{state: :ready})
    assert :ok = Tay.Standalone.Health.check!(%{state: :compacting, phase: :preparing})
    assert :ok = Tay.Standalone.Health.check!(%{state: :compacting, phase: :switching})

    assert_raise RuntimeError, ~r/not ready/, fn ->
      Tay.Standalone.Health.check!(%{state: :recovering})
    end
  end
end
