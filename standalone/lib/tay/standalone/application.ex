defmodule Tay.Standalone.Application do
  @moduledoc false

  use Application

  @dashboard_application Module.concat([Tay, Dashboard, Standalone, Application])

  @impl true
  def start(_type, _args) do
    environment = Application.get_env(:tay_standalone, :environment, System.get_env())

    with {:ok, config} <- Tay.Standalone.Config.load(environment),
         {:ok, dashboard_children} <- dashboard_children(environment) do
      engine_children =
        if Application.get_env(:tay_standalone, :start_runtime, true) do
          [
            Tay.child_spec(
              data_dir: config.data_dir,
              initialize: config.initialize,
              durability: :sync,
              group_commit_interval_ms: config.group_commit_interval_ms,
              validated_filesystem: true,
              workers: %{},
              queues: [default: config.default_queue_concurrency],
              caller_timeout: config.caller_timeout_ms,
              max_state_bytes: config.max_state_bytes,
              compaction: [
                terminal_retention: config.terminal_retention,
                checkpoint_interval: config.checkpoint_interval_ms
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

  defp dashboard_children(environment) do
    case Application.fetch_env!(:tay_standalone, :flavor) do
      :dashboard -> apply(@dashboard_application, :children, [environment])
      _ -> dashboard_disabled(environment)
    end
  end

  defp dashboard_disabled(environment) do
    case Map.get(environment, "TAY_ENABLE_DASHBOARD", "false") do
      value when value in ["false", "FALSE", "0"] ->
        {:ok, []}

      value when value in ["true", "TRUE", "1"] ->
        {:error, "dashboard is not included in this release"}

      _ ->
        {:error, "TAY_ENABLE_DASHBOARD must be one of true, false, TRUE, FALSE, 1, or 0"}
    end
  end
end
