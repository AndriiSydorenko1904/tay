defmodule Tay.Engine.ConfigTest do
  use ExUnit.Case, async: true
  alias Tay.Engine.Config

  test "appendix option names, defaults, exact domains and conservative cross-budget checks" do
    base = [data_dir: "tmp/config-only", durability: :write]
    assert {:ok, c} = Config.new(base)
    assert c.initialize == :never
    assert {:ok, %{initialize: :if_missing}} = Config.new(base ++ [initialize: :if_missing])

    assert {c.max_insert_payload_bytes, c.max_insert_args_bytes, c.insert_value_depth,
            c.insert_value_nodes} == {1_048_576, 262_144, 32, 10_000}

    assert is_binary(c.executor_socket)
    refute String.starts_with?(c.executor_socket, Path.expand("tmp/config-only") <> "/")
    assert c.executor_socket_private_directory

    assert {:ok, disabled} = Config.new(base ++ [executor_socket: nil])
    assert disabled.executor_socket == nil
    refute disabled.executor_socket_private_directory

    for extra <- [
          [max_insert_payload_bytes: 0],
          [max_insert_payload_bytes: 16_777_217],
          [max_insert_args_bytes: 4],
          [max_insert_args_bytes: 16_777_217],
          [insert_value_depth: 0],
          [insert_value_nodes: 0],
          [insert_depth: 32],
          [rotation_target_bytes: 1],
          [rotation_target_bytes: 1_073_741_825],
          [recovery: [max_decode_payload_bytes: 1024]],
          [
            recovery: [event_limits: %{depth: 31, output_nodes: 10_000, binary_bytes: 16_777_216}]
          ],
          [recovery: [event_limits: %{depth: 64, output_nodes: 9999, binary_bytes: 16_777_216}]],
          [recovery: [event_limits: %{depth: 64, output_nodes: 100_000, binary_bytes: 1024}]],
          [name: "never-create-atom"],
          [workers: %{"" => __MODULE__}],
          [workers: %{"w" => "Elixir.NeverFromDisk"}],
          [client_slots: 0],
          [client_bytes: 1],
          [caller_timeout: :infinity],
          [initialize: :always],
          [initialize: true],
          [bootstrap: true]
        ],
        do: assert({:error, %Tay.Error{kind: :invalid}} = Config.new(Keyword.merge(base, extra)))

    assert {:ok, _} = Config.new(base ++ [max_insert_payload_bytes: 1, max_insert_args_bytes: 5])

    assert {:error, _} =
             Config.new(base ++ [executor_socket: Path.expand("tmp/config-only/tay.sock")])

    assert {:ok, config} =
             Config.new(base ++ [executor_socket: Path.expand("tmp/tay-config-only.sock")])

    assert config.executor_max_results == 10_000
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

  test "gRPC requires complete mTLS configuration outside loopback" do
    base = [data_dir: "tmp/config-only", durability: :write, grpc_port: 50_051]

    assert {:error, _} = Config.new(base ++ [grpc_ip: "0.0.0.0"])
    assert {:error, _} = Config.new(base ++ [grpc_tls_certfile: "/cert.pem"])

    assert {:ok, config} =
             Config.new(
               base ++
                 [
                   grpc_ip: "0.0.0.0",
                   grpc_tls_certfile: "/cert.pem",
                   grpc_tls_keyfile: "/key.pem",
                   grpc_tls_cacertfile: "/ca.pem"
                 ]
             )

    assert config.grpc_tls_cacertfile == "/ca.pem"
  end
end
