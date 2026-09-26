defmodule Tay.GRPC.Listener do
  @moduledoc false
  use GenServer

  @runtime_key {__MODULE__, :runtime}

  def child_spec(options) do
    %{
      id: {__MODULE__, Map.fetch!(options, :port)},
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  def runtime do
    case :persistent_term.get(@runtime_key, nil) do
      %{owner: owner} = runtime when is_pid(owner) ->
        if Process.alive?(owner), do: {:ok, runtime}, else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  @impl true
  def init(options) do
    with {:ok, runtime} <- runtime_options(options),
         :ok <- claim_runtime(runtime),
         {:ok, grpc_supervisor} <-
           GRPC.Server.Supervisor.start_link(
             endpoint: Tay.GRPC.Endpoint,
             port: runtime.port,
             start_server: true,
             adapter_opts: adapter_options(runtime),
             max_body_size: runtime.max_message_bytes
           ) do
      Process.flag(:trap_exit, true)
      {:ok, Map.put(runtime, :grpc_supervisor, grpc_supervisor)}
    else
      {:error, _} = error ->
        clear_runtime(self())
        {:stop, error}
    end
  end

  @impl true
  def handle_info({:EXIT, grpc_supervisor, reason}, %{grpc_supervisor: grpc_supervisor} = state),
    do: {:stop, {:grpc_server_stopped, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{grpc_supervisor: supervisor, owner: owner}) do
    if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    clear_runtime(owner)
    :ok
  end

  defp runtime_options(%{
         engine_name: engine_name,
         executor_server: executor_server,
         port: port,
         ip: ip,
         max_message_bytes: max_message_bytes,
         tls_certfile: tls_certfile,
         tls_keyfile: tls_keyfile,
         tls_cacertfile: tls_cacertfile
       })
       when is_atom(engine_name) and (is_pid(executor_server) or is_nil(executor_server)) and
              is_integer(port) and port in 1..65_535 and is_integer(max_message_bytes) and
              max_message_bytes in 1..16_777_216 do
    with {:ok, parsed_ip} <- :inet.parse_address(String.to_charlist(ip)),
         :ok <- validate_tls_files(tls_certfile, tls_keyfile, tls_cacertfile) do
      {:ok,
       %{
         engine_name: engine_name,
         executor_server: executor_server,
         port: port,
         ip: parsed_ip,
         max_message_bytes: max_message_bytes,
         tls_certfile: tls_certfile,
         tls_keyfile: tls_keyfile,
         tls_cacertfile: tls_cacertfile,
         owner: self()
       }}
    else
      _ -> {:error, :invalid_grpc_options}
    end
  end

  defp runtime_options(_), do: {:error, :invalid_grpc_options}

  # One endpoint module has one static dispatch table. Explicitly reject a
  # second listener in the same VM rather than let a later startup silently
  # route requests to the wrong Engine generation.
  defp claim_runtime(runtime) do
    case runtime() do
      {:ok, _} -> {:error, :grpc_listener_already_running}
      {:error, :unavailable} -> :persistent_term.put(@runtime_key, runtime)
    end
  end

  defp clear_runtime(owner) do
    case :persistent_term.get(@runtime_key, nil) do
      %{owner: ^owner} -> :persistent_term.erase(@runtime_key)
      _ -> :ok
    end
  end

  defp validate_tls_files(nil, nil, nil), do: :ok

  defp validate_tls_files(certfile, keyfile, cacertfile) do
    if Enum.all?([certfile, keyfile, cacertfile], &File.regular?/1),
      do: :ok,
      else: {:error, :invalid_grpc_tls_files}
  end

  defp adapter_options(%{ip: ip} = runtime) do
    network = if tuple_size(ip) == 8, do: [ip: ip, net: :inet6], else: [ip: ip]

    if runtime.tls_certfile do
      ssl = [
        certfile: String.to_charlist(runtime.tls_certfile),
        keyfile: String.to_charlist(runtime.tls_keyfile),
        cacertfile: String.to_charlist(runtime.tls_cacertfile),
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        versions: [:"tlsv1.3", :"tlsv1.2"]
      ]

      network ++ [cred: GRPC.Credential.new(ssl: ssl)]
    else
      network
    end
  end
end
