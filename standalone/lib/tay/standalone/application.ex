defmodule Tay.Standalone.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    environment = Application.get_env(:tay_standalone, :environment, System.get_env())

    with {:ok, config} <- Tay.Standalone.Config.load(environment),
         {:ok, dashboard_children} <- Tay.Dashboard.Standalone.Application.children(environment) do
      engine_children =
        if Application.get_env(:tay_standalone, :start_runtime, true) do
          [
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
              http_port: config.http_port,
              http_ip: config.http_ip,
              http_tls_certfile: config.http_tls_certfile,
              http_tls_keyfile: config.http_tls_keyfile,
              http_tls_cacertfile: config.http_tls_cacertfile
            )
            |> Map.put(:significant, true)
          ]
        else
          []
        end

      Supervisor.start_link(engine_children ++ dashboard_children,
        strategy: :one_for_one,
        auto_shutdown: :any_significant,
        name: Tay.Standalone.Supervisor
      )
    else
      {:error, {:invalid_dashboard_configuration, _} = reason} -> {:error, reason}
      {:error, message} -> {:error, {:invalid_runtime_configuration, message}}
    end
  end
end
