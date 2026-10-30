defmodule Tay.Standalone.ConfigTest do
  use ExUnit.Case, async: true

  alias Tay.Standalone.Config

  test "uses standalone container defaults" do
    assert {:ok, config} = Config.load(%{})
    assert config.data_dir == "/var/lib/tay"
    assert {:ok, socket} = Tay.Gateway.Config.resolve_socket(:auto, nil, env: %{})
    assert config.socket_path == socket.path
    assert config.socket.path == socket.path
    assert config.socket.private_directory == socket.private_directory
    assert config.initialize == :never
    assert config.default_queue_concurrency == 10
    assert config.caller_timeout_ms == 5_000
    assert config.group_commit_interval_ms == 0
    assert config.checkpoint_interval_ms == 60_000
  end

  test "blank socket environment uses the same defaults as an absent value" do
    assert Config.load(%{"TAY_SOCKET_PATH" => ""}) == Config.load(%{})

    assert {:ok, %{socket_path: nil}} =
             Config.load(%{"TAY_SOCKET_PATH" => "", "TAY_HTTP_PORT" => "8080"})
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

  test "HTTP configuration disables the implicit socket but permits an explicit socket" do
    assert {:ok, %{socket_path: nil}} = Config.load(%{"TAY_HTTP_PORT" => "8080"})

    assert {:ok, %{socket_path: "/run/tay/custom.sock"}} =
             Config.load(%{
               "TAY_HTTP_PORT" => "8080",
               "TAY_SOCKET_PATH" => "/run/tay/custom.sock"
             })
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

    assert {:error, message} = Config.load(%{"TAY_SOCKET_PATH" => " "})
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

  test "parses binary active-state byte units" do
    for {value, expected} <- [
          {"0", 0},
          {"5KB", 5_120},
          {"5MB", 5_242_880},
          {"5GB", 5_368_709_120}
        ] do
      assert {:ok, config} = Config.load(%{"TAY_MAX_STATE_BYTES" => value})
      assert config.max_state_bytes == expected
    end
  end

  test "rejects malformed active-state byte units" do
    for value <- ["5K", "5KiB", "5gb", "5TB", "1.5MB", " 5GB", "05GB", "-1"] do
      assert {:error, message} = Config.load(%{"TAY_MAX_STATE_BYTES" => value})
      assert message =~ "KB, MB, or GB"
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

  test "resolved automatic socket survives the handoff into Engine configuration" do
    directory = Path.join("/tmp", "tay-handoff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:ok, config} = Config.load(%{"XDG_RUNTIME_DIR" => directory, "TMPDIR" => directory})

    assert {:ok, engine} =
             Tay.Gateway.Config.resolve(
               Map.put(Tay.Gateway.Config.defaults(), :executor_socket, config.socket),
               "/var/lib/tay"
             )

    assert engine.executor_socket == config.socket_path
    assert engine.executor_socket_private_directory == config.socket.private_directory
  end

  test "standalone and embedded hosts share HTTP/TLS acceptance rules" do
    alias Tay.Gateway.Config, as: GatewayConfig

    for {port, ip, cert, key, ca} <- [
          {nil, "0.0.0.0", nil, nil, nil},
          {8080, "127.0.0.1", nil, nil, nil},
          {8080, "::1", nil, nil, nil},
          {8080, "0.0.0.0", nil, nil, nil},
          {8080, "0.0.0.0", "/cert", "/key", "/ca"},
          {nil, "127.0.0.1", "/cert", "/key", "/ca"},
          {8080, "127.0.0.1", "/cert", nil, nil},
          {8080, "127.0.0.1", "/cert", "relative", "/ca"},
          {8080, "invalid", nil, nil, nil},
          {8080, "127.0.0.1", "/cert", "/key", "/ca" <> <<0>>}
        ] do
      environment = %{
        "TAY_HTTP_PORT" => if(port, do: Integer.to_string(port), else: ""),
        "TAY_HTTP_IP" => ip,
        "TAY_HTTP_TLS_CERTFILE" => cert || "",
        "TAY_HTTP_TLS_KEYFILE" => key || "",
        "TAY_HTTP_TLS_CACERTFILE" => ca || ""
      }

      gateway =
        Map.merge(GatewayConfig.defaults(), %{
          http_port: port,
          http_ip: ip,
          http_tls_certfile: cert,
          http_tls_keyfile: key,
          http_tls_cacertfile: ca
        })

      assert match?({:ok, _}, Config.load(environment)) ==
               (GatewayConfig.validate_http(gateway) == :ok)
    end
  end

  test "rate limits use bounded JSON policies and reject unknown queue names" do
    value =
      ~s({"queues":{"default":{"limit":5,"interval_ms":1000}},"tasks":{"task.v1":{"limit":1,"interval_ms":5000}}})

    assert {:ok, config} = Config.load(%{"TAY_RATE_LIMITS" => value})
    assert config.rate_limits[:queues]["default"] == %{limit: 5, interval_ms: 1000}

    for invalid <- [
          "null",
          "[]",
          "{",
          ~s({"queues":{"unknown":{"limit":1,"interval_ms":1}}}),
          ~s({"tasks":{"task.v1":{"limit":true,"interval_ms":1}}}),
          ~s({"unknown":{}})
        ] do
      assert {:error, message} = Config.load(%{"TAY_RATE_LIMITS" => invalid})
      assert message =~ "TAY_RATE_LIMITS"
    end
  end
end
