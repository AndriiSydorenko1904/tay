defmodule Tay.Standalone.ConfigTest do
  use ExUnit.Case, async: true

  alias Tay.Standalone.Config

  test "uses standalone container defaults" do
    assert {:ok, config} = Config.load(%{})
    assert config.data_dir == "/var/lib/tay"
    assert config.socket_path == "/run/tay/tay.sock"
    assert config.initialize == :never
    assert config.default_queue_concurrency == 10
    assert config.caller_timeout_ms == 5_000
    assert config.group_commit_interval_ms == 0
    assert config.checkpoint_interval_ms == 60_000
  end

  test "configures the Engine caller timeout" do
    assert {:ok, %{caller_timeout_ms: 25_000}} =
             Config.load(%{"TAY_CALLER_TIMEOUT_MS" => "25000"})

    for value <- ["0", "4294967296", "-1", "5s", ""] do
      assert {:error, message} = Config.load(%{"TAY_CALLER_TIMEOUT_MS" => value})
      assert message =~ "TAY_CALLER_TIMEOUT_MS"
    end
  end

  test "configures the default queue concurrency" do
    for concurrency <- [1, 10, 20, 100, 65_536] do
      assert {:ok, config} =
               Config.load(%{"TAY_DEFAULT_QUEUE_CONCURRENCY" => Integer.to_string(concurrency)})

      assert config.default_queue_concurrency == concurrency
    end

    for value <- ["0", "65537", "-1", "1.5", "many"] do
      assert {:error, message} = Config.load(%{"TAY_DEFAULT_QUEUE_CONCURRENCY" => value})
      assert message =~ "TAY_DEFAULT_QUEUE_CONCURRENCY"
    end
  end

  test "validates the durable enqueue group-commit interval" do
    for interval <- [0, 1, 5, 10, 50, 100, 1_000] do
      assert {:ok, config} =
               Config.load(%{"TAY_GROUP_COMMIT_INTERVAL_MS" => Integer.to_string(interval)})

      assert config.group_commit_interval_ms == interval
    end

    for value <- ["-1", "1001", "1.0", " 5", "", "five"] do
      assert {:error, message} = Config.load(%{"TAY_GROUP_COMMIT_INTERVAL_MS" => value})
      assert message =~ "TAY_GROUP_COMMIT_INTERVAL_MS"
    end
  end

  test "configures periodic semantic checkpoints" do
    for interval <- [0, 1_000, 60_000, 4_294_967_295] do
      assert {:ok, config} =
               Config.load(%{"TAY_CHECKPOINT_INTERVAL_MS" => Integer.to_string(interval)})

      assert config.checkpoint_interval_ms == interval
    end

    for value <- ["-1", "4294967296", "1.0", " 1000", "", "minute"] do
      assert {:error, message} = Config.load(%{"TAY_CHECKPOINT_INTERVAL_MS" => value})
      assert message =~ "TAY_CHECKPOINT_INTERVAL_MS"
    end
  end

  test "allows HTTP-only runtime without a Unix socket" do
    assert {:ok, config} = Config.load(%{"TAY_SOCKET_PATH" => "off", "TAY_HTTP_PORT" => "8080"})
    assert config.socket_path == nil
    assert {:error, _} = Config.load(%{"TAY_SOCKET_PATH" => "off"})
  end

  test "rejects legacy gRPC settings on the Elixir runtime" do
    assert {:error, message} = Config.load(%{"TAY_GRPC_PORT" => "50051"})
    assert message =~ "TAY_HTTP_*"

    assert {:ok, config} = Config.load(%{"TAY_HTTP_PORT" => "8080"})
    assert config.http_port == 8080
    assert {:error, _} = Config.load(%{"TAY_HTTP_PORT" => "65536"})
    assert {:error, _} = Config.load(%{"TAY_HTTP_PORT" => "8080", "TAY_HTTP_IP" => "0.0.0.0"})
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

  test "loads one active-state byte budget and ignores the legacy node setting" do
    assert {:ok, config} =
             Config.load(%{
               "TAY_MAX_STATE_BYTES" => "4294967296",
               "TAY_MAX_STATE_NODES" => "100000000"
             })

    assert config.max_state_bytes == 4_294_967_296
    refute Map.has_key?(config, :max_state_nodes)
    assert {:ok, _} = Config.load(%{"TAY_MAX_STATE_NODES" => "not-used"})

    assert {:error, message} = Config.load(%{"TAY_MAX_STATE_BYTES" => "-1"})
    assert message =~ "TAY_MAX_STATE_BYTES"
  end

  test "parses decimal and binary active-state byte units" do
    for {value, expected} <- [
          {"0", 0},
          {"5KB", 5_000},
          {"5KiB", 5_120},
          {"5MB", 5_000_000},
          {"5MiB", 5_242_880},
          {"5GB", 5_000_000_000},
          {"5GiB", 5_368_709_120}
        ] do
      assert {:ok, config} = Config.load(%{"TAY_MAX_STATE_BYTES" => value})
      assert config.max_state_bytes == expected
    end
  end

  test "rejects malformed active-state byte units" do
    for value <- ["5K", "5Gi", "5gb", "5TB", "1.5GiB", " 5GiB", "05GiB", "-1"] do
      assert {:error, message} = Config.load(%{"TAY_MAX_STATE_BYTES" => value})
      assert message =~ "KB, KiB, MB, MiB, GB, or GiB"
    end
  end

  test "legacy job-count environment variables do not impose limits" do
    assert {:ok, config} =
             Config.load(%{"TAY_MAX_JOBS" => "0", "TAY_MAX_TERMINAL_JOBS" => "0"})

    refute Map.has_key?(config, :max_jobs)
    refute Map.has_key?(config, :max_terminal_jobs)
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
