defmodule Tay.HTTP.Listener do
  @moduledoc false
  use GenServer

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

  @impl true
  def init(options) do
    with {:ok, ip} <- :inet.parse_address(String.to_charlist(options.ip)),
         :ok <- validate_tls_files(options),
         {:ok, bandit} <- Bandit.start_link(bandit_options(options, ip)) do
      Process.flag(:trap_exit, true)
      {:ok, bandit}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, bandit, reason}, bandit),
    do: {:stop, {:http_transport_stopped, reason}, bandit}

  def handle_info(_, bandit), do: {:noreply, bandit}

  @impl true
  def terminate(_, bandit) when is_pid(bandit) do
    if Process.alive?(bandit), do: Process.exit(bandit, :shutdown)
    :ok
  end

  defp validate_tls_files(%{tls_certfile: nil, tls_keyfile: nil, tls_cacertfile: nil}),
    do: :ok

  defp validate_tls_files(options) do
    if Enum.all?(
         [options.tls_certfile, options.tls_keyfile, options.tls_cacertfile],
         &File.regular?/1
       ),
       do: :ok,
       else: {:error, :invalid_http_tls_files}
  end

  defp bandit_options(options, ip) do
    base = [
      plug: {Tay.HTTP.Router, options},
      port: options.port,
      ip: ip,
      startup_log: false
    ]

    if options.tls_certfile do
      base ++
        [
          scheme: :https,
          certfile: options.tls_certfile,
          keyfile: options.tls_keyfile,
          thousand_island_options: [
            transport_options: [
              cacertfile: options.tls_cacertfile,
              verify: :verify_peer,
              fail_if_no_peer_cert: true,
              versions: [:"tlsv1.3", :"tlsv1.2"]
            ]
          ]
        ]
    else
      base
    end
  end
end
