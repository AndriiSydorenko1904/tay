defmodule Tay.Gateway.Runtime do
  @moduledoc false

  alias Tay.Executor.Server
  alias Tay.Schedule.Coordinator

  @http_listener Module.concat([Tay, HTTP, Listener])

  def start(supervisor, engine, config, recovered) do
    with {:ok, coordinator} <- start_coordinator(supervisor, config, recovered),
         {:ok, executor_server} <-
           start_executor(supervisor, engine, coordinator, config, recovered),
         :ok <- start_http(supervisor, executor_server, config) do
      {:ok, executor_server}
    end
  end

  defp start_coordinator(_supervisor, config, _recovered)
       when is_nil(config.executor_socket) and is_nil(config.http_port),
       do: {:ok, nil}

  defp start_coordinator(supervisor, config, recovered) do
    start_child(
      supervisor,
      {Coordinator, %{core: {Tay.Core.Local, config.name}, schedules: recovered.schedules}}
    )
  end

  defp start_executor(_supervisor, _engine, _coordinator, config, _recovered)
       when is_nil(config.executor_socket) and is_nil(config.http_port),
       do: {:ok, nil}

  defp start_executor(supervisor, engine, coordinator, config, _recovered) do
    start_child(
      supervisor,
      {Server,
       %{
         engine: engine,
         schedule_coordinator: coordinator,
         socket_path: config.executor_socket,
         socket_mode: config.executor_socket_mode,
         private_directory: config.executor_socket_private_directory,
         max_frame_bytes: config.executor_max_frame_bytes,
         max_connections: config.executor_max_connections,
         max_tasks_per_connection: config.executor_max_tasks_per_connection,
         result_bytes: config.executor_result_bytes,
         error_bytes: config.executor_error_bytes,
         engine_name: config.name
       }}
    )
  end

  defp start_http(_supervisor, _executor_server, %{http_port: nil}), do: :ok

  defp start_http(supervisor, executor_server, config) do
    with {:module, _} <- Code.ensure_loaded(@http_listener),
         result <-
           start_child(
             supervisor,
             {@http_listener,
              %{
                engine_name: config.name,
                executor_server: executor_server,
                port: config.http_port,
                ip: config.http_ip,
                max_body_bytes: config.http_max_body_bytes,
                result_bytes: config.executor_result_bytes,
                error_bytes: config.executor_error_bytes,
                tls_certfile: config.http_tls_certfile,
                tls_keyfile: config.http_tls_keyfile,
                tls_cacertfile: config.http_tls_cacertfile
              }}
           ) do
      case result do
        {:ok, _listener} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} -> {:error, :tay_http_not_installed}
    end
  end

  defp start_child(supervisor, child_spec) do
    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :ignored_child}
    end
  end
end
