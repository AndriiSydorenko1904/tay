defmodule Tay.Engine.ConfigTest do
  use ExUnit.Case, async: false
  alias Tay.Engine.Config

  test "recovery exposes only supported budgets and rejects removed aggregate limits" do
    base = [data_dir: "tmp/config-only", durability: :write]
    assert {:ok, config} = Config.new(base)

    assert Enum.sort(Keyword.keys(config.recovery)) ==
             Enum.sort([
               :deadline_ms
             ])

    for key <- [
          :max_replay_records,
          :max_total_segment_bytes,
          :event_limits
        ] do
      assert {:error, %Tay.Storage.Recovery.Error{reason: :invalid_recovery_options}} =
               Tay.Storage.Recovery.options([{key, :infinity}])

      assert {:error, %Tay.Error{kind: :invalid}} = Config.new(base ++ [recovery: [{key, 1}]])
    end
  end

  test "appendix option names, defaults, exact domains and conservative cross-budget checks" do
    base = [data_dir: "tmp/config-only", durability: :write]
    assert {:ok, c} = Config.new(base)
    assert c.initialize == :never

    assert {:ok, %{initialize: :if_missing}} = Config.new(base ++ [initialize: :if_missing])

    assert c.value_limits == Tay.Event.Value.defaults()

    assert is_binary(c.executor_socket)
    refute String.starts_with?(c.executor_socket, Path.expand("tmp/config-only") <> "/")
    assert c.executor_socket_private_directory

    assert {:ok, disabled} = Config.new(base ++ [executor_socket: nil])
    assert disabled.executor_socket == nil
    refute disabled.executor_socket_private_directory

    for extra <- [
          [max_insert_args_bytes: 4],
          [max_insert_args_bytes: 16_777_217],
          [insert_value_depth: 0],
          [insert_value_nodes: 0],
          [insert_depth: 32],
          [
            recovery: [event_limits: %{depth: 31, output_nodes: 10_000, binary_bytes: 16_777_216}]
          ],
          [recovery: [event_limits: %{depth: 64, output_nodes: 9999, binary_bytes: 16_777_216}]],
          [recovery: [event_limits: %{depth: 64, output_nodes: 100_000, binary_bytes: 1024}]],
          [name: "never-create-atom"],
          [workers: %{"" => __MODULE__}],
          [workers: %{"w" => "Elixir.NeverFromDisk"}],
          [client_slots: 0],
          [client_bytes: 0],
          [caller_timeout: :infinity],
          [initialize: :always],
          [initialize: true],
          [bootstrap: true]
        ],
        do: assert({:error, %Tay.Error{kind: :invalid}} = Config.new(Keyword.merge(base, extra)))

    assert {:error, _} =
             Config.new(base ++ [executor_socket: Path.expand("tmp/config-only/tay.sock")])

    assert {:ok, _config} =
             Config.new(base ++ [executor_socket: Path.expand("tmp/tay-config-only.sock")])

    assert {:error, _} = Config.new(base ++ [durability: :write])
    assert {:error, _} = Config.new(:bad)
  end

  test "sync has no silent platform or unvalidated-filesystem fallback" do
    assert {:error, _} = Config.new(data_dir: "tmp/config-only", durability: :sync)

    if :os.type() != {:unix, :linux} do
      assert {:error, _} =
               Config.new(
                 data_dir: "tmp/config-only",
                 durability: :sync,
                 validated_filesystem: true
               )
    end
  end

  test "rejects removed compatibility options instead of silently ignoring them" do
    base = [data_dir: "tmp/config-only", durability: :write]

    for key <- [
          :max_jobs,
          :max_state_nodes,
          :executor_max_results,
          :group_commit_interval_ms,
          :max_insert_args_bytes,
          :insert_value_depth,
          :insert_value_nodes,
          :max_segments
        ],
        value <- [0, 1, 10_000] do
      assert {:error, %Tay.Error{kind: :invalid}} = Config.new(base ++ [{key, value}])
    end
  end

  test "HTTP binds to loopback unless complete mTLS is configured" do
    base = [data_dir: "tmp/config-only", durability: :write]
    assert {:ok, %{http_port: 8080, executor_socket: nil}} = Config.new(base ++ [http_port: 8080])

    assert {:ok, %{executor_socket: "/tmp/tay-explicit.sock"}} =
             Config.new(base ++ [http_port: 8080, executor_socket: "/tmp/tay-explicit.sock"])

    assert {:error, _} = Config.new(base ++ [http_port: 8080, http_ip: "0.0.0.0"])

    assert {:ok, %{executor_socket: nil}} =
             Config.new(base ++ [http_port: 8080, executor_socket: nil])

    assert {:error, _} = Config.new(base ++ [http_port: 0])
    assert {:error, _} = Config.new(base ++ [http_port: 8080, http_tls_certfile: "/cert.pem"])

    assert {:ok, _} =
             Config.new(
               base ++
                 [
                   http_port: 8080,
                   http_ip: "0.0.0.0",
                   http_tls_certfile: "/cert.pem",
                   http_tls_keyfile: "/key.pem",
                   http_tls_cacertfile: "/ca.pem"
                 ]
             )
  end

  test "a pre-resolved endpoint reaches the Engine without a second environment lookup" do
    alias Tay.Executor.SocketPath

    assert {:ok, socket} =
             SocketPath.resolve(:auto,
               env: %{"XDG_RUNTIME_DIR" => "/frozen-runtime"},
               uid: 4242,
               directory_exists: fn _ -> false end,
               usable_directory: fn _, _ -> true end
             )

    assert {:ok, engine} =
             Config.new(
               data_dir: "/var/lib/tay",
               durability: :write,
               executor_socket: SocketPath.freeze(socket)
             )

    assert engine.executor_socket == "/frozen-runtime/tay/tay.sock"
    assert engine.executor_socket_private_directory
  end
end
