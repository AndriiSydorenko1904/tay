defmodule Tay.Standalone.ConfigTest do
  use ExUnit.Case, async: true

  alias Tay.Standalone.Config

  test "uses standalone container defaults" do
    assert {:ok, config} = Config.load(%{})
    assert config.data_dir == "/var/lib/tay"
    assert config.socket_path == "/run/tay/tay.sock"
    assert config.initialize == :never
  end

  test "accepts explicit initialization values" do
    for {value, expected} <- [
          {"true", :if_missing},
          {"TRUE", :if_missing},
          {"1", :if_missing},
          {"false", :never},
          {"FALSE", :never},
          {"0", :never}
        ] do
      assert {:ok, config} = Config.load(%{"TAY_INITIALIZE_IF_MISSING" => value})
      assert config.initialize == expected
    end
  end

  test "rejects malformed explicit configuration" do
    assert {:error, message} = Config.load(%{"TAY_INITIALIZE_IF_MISSING" => "yes"})
    assert message =~ "TAY_INITIALIZE_IF_MISSING"

    assert {:error, message} = Config.load(%{"TAY_DATA_DIR" => "relative"})
    assert message =~ "absolute path"

    assert {:error, message} = Config.load(%{"TAY_SOCKET_PATH" => ""})
    assert message =~ "must not be blank"
  end

  test "loads bounded state and terminal-history budgets" do
    assert {:ok, config} =
             Config.load(%{
               "TAY_MAX_JOBS" => "1000000",
               "TAY_MAX_STATE_BYTES" => "4294967296",
               "TAY_MAX_STATE_NODES" => "100000000",
               "TAY_MAX_TERMINAL_JOBS" => "5000"
             })

    assert config.max_jobs == 1_000_000
    assert config.max_state_bytes == 4_294_967_296
    assert config.max_state_nodes == 100_000_000
    assert config.max_terminal_jobs == 5_000

    for name <- ~w(TAY_MAX_JOBS TAY_MAX_STATE_BYTES TAY_MAX_STATE_NODES TAY_MAX_TERMINAL_JOBS) do
      assert {:error, message} = Config.load(%{name => "-1"})
      assert message =~ name
    end
  end

  test "requires the runtime socket to remain outside durable storage" do
    assert {:error, message} =
             Config.load(%{
               "TAY_DATA_DIR" => "/var/lib/tay",
               "TAY_SOCKET_PATH" => "/var/lib/tay/tay.sock"
             })

    assert message =~ "outside TAY_DATA_DIR"
  end
end
