defmodule Tay.Standalone.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    case {Application.get_env(:tay_standalone, :start_runtime, true),
          Tay.Standalone.Config.load()} do
      {false, {:ok, _config}} ->
        Supervisor.start_link([],
          strategy: :one_for_one,
          name: Tay.Standalone.Supervisor
        )

      {true, {:ok, config}} ->
        children = [
          Tay.child_spec(
            data_dir: config.data_dir,
            initialize: config.initialize,
            durability: :sync,
            validated_filesystem: true,
            workers: %{},
            queues: [default: 10],
            max_jobs: config.max_jobs,
            max_state_bytes: config.max_state_bytes,
            max_state_nodes: config.max_state_nodes,
            compaction: [
              max_terminal_jobs: config.max_terminal_jobs,
              terminal_retention: config.terminal_retention
            ],
            executor_socket: config.socket_path,
            executor_socket_mode: 0o660,
            grpc_port: config.grpc_port,
            grpc_ip: config.grpc_ip,
            grpc_tls_certfile: config.grpc_tls_certfile,
            grpc_tls_keyfile: config.grpc_tls_keyfile,
            grpc_tls_cacertfile: config.grpc_tls_cacertfile
          )
          |> Map.put(:significant, true)
        ]

        Supervisor.start_link(children,
          strategy: :one_for_one,
          auto_shutdown: :any_significant,
          name: Tay.Standalone.Supervisor
        )

      {_, {:error, message}} ->
        {:error, {:invalid_runtime_configuration, message}}
    end
  end
end
