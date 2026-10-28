defmodule Tay.Gateway.Config do
  @moduledoc false

  alias Tay.Executor.SocketPath

  @kib 1_024
  @mib 1_048_576
  @max_payload 16 * @mib

  @defaults %{
    executor_socket: :auto,
    executor_socket_mode: 0o600,
    executor_max_frame_bytes: 1 * @mib,
    executor_max_connections: 128,
    executor_max_tasks_per_connection: 256,
    executor_result_bytes: 64 * @kib,
    executor_error_bytes: 8 * @kib,
    # Compatibility-only: gateway result caching was removed in favour of Core.
    executor_max_results: 10_000,
    http_port: nil,
    http_ip: "127.0.0.1",
    http_max_body_bytes: 1 * @mib,
    http_tls_certfile: nil,
    http_tls_keyfile: nil,
    http_tls_cacertfile: nil
  }

  def defaults, do: @defaults

  def resolve(config, data_dir) do
    with {:ok, socket} <- resolve_socket(config.executor_socket, config.http_port),
         resolved <-
           config
           |> Map.put(:executor_socket, socket.path)
           |> Map.put(:executor_socket_private_directory, socket.private_directory),
         :ok <- validate(resolved, data_dir) do
      {:ok, resolved}
    end
  end

  # Transport selection belongs here so embedded and standalone hosts use the
  # same opt-out and HTTP-only defaults. Explicit paths always enable UDS.
  def resolve_socket(setting, http_port, options \\ [])

  def resolve_socket(%SocketPath{} = socket, _http_port, options),
    do: SocketPath.resolve(socket, options)

  def resolve_socket(setting, http_port, options) do
    environment = Keyword.get(options, :env, System.get_env())

    setting =
      if setting == :auto do
        case Map.get(environment, "TAY_SOCKET_PATH") do
          "off" -> nil
          value when value in [nil, ""] -> if is_nil(http_port), do: :auto, else: nil
          _ -> :auto
        end
      else
        setting
      end

    SocketPath.resolve(setting, options)
  end

  def validate(c, data_dir) do
    positive = [
      :executor_max_frame_bytes,
      :executor_max_connections,
      :executor_max_tasks_per_connection,
      :executor_result_bytes,
      :executor_error_bytes,
      :executor_max_results,
      :http_max_body_bytes
    ]

    checks = [
      Enum.all?(positive, &(is_integer(c[&1]) and c[&1] > 0)),
      socket?(c.executor_socket),
      c.executor_socket_mode in [0o600, 0o660],
      is_boolean(c.executor_socket_private_directory),
      socket_outside_data_dir?(c.executor_socket, data_dir),
      c.executor_max_frame_bytes <= @max_payload,
      c.executor_result_bytes <= c.executor_max_frame_bytes,
      c.executor_error_bytes <= c.executor_max_frame_bytes,
      c.executor_max_results <= 100_000,
      c.http_max_body_bytes <= @max_payload
    ]

    if Enum.all?(checks) and validate_http(c) == :ok,
      do: :ok,
      else: {:error, :invalid_gateway_options}
  end

  defp socket?(nil), do: true

  defp socket?(path) when is_binary(path),
    do:
      path != "" and byte_size(path) <= 100 and String.valid?(path) and
        not String.contains?(path, <<0>>) and Path.type(path) == :absolute

  defp socket?(_), do: false

  defp ip?(ip) when is_binary(ip),
    do: match?({:ok, _}, :inet.parse_address(String.to_charlist(ip)))

  defp ip?(_), do: false

  @doc "Validates HTTP addressing and TLS policy for every host."
  def validate_http(c) do
    files = [c.http_tls_certfile, c.http_tls_keyfile, c.http_tls_cacertfile]

    cond do
      not (is_nil(c.http_port) or (is_integer(c.http_port) and c.http_port in 1..65_535)) ->
        {:error, :invalid_http_port}

      not ip?(c.http_ip) ->
        {:error, :invalid_http_ip}

      Enum.all?(files, &is_nil/1) ->
        if is_nil(c.http_port) or loopback?(c.http_ip),
          do: :ok,
          else: {:error, :http_tls_required}

      not Enum.all?(files, &tls_path?/1) ->
        {:error, :invalid_http_tls_paths}

      is_nil(c.http_port) ->
        {:error, :http_port_required}

      true ->
        :ok
    end
  end

  defp tls_path?(path) when is_binary(path),
    do:
      path != "" and String.valid?(path) and not String.contains?(path, <<0>>) and
        Path.type(path) == :absolute

  defp tls_path?(_), do: false

  defp loopback?(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  defp socket_outside_data_dir?(nil, _), do: true

  defp socket_outside_data_dir?(socket, data_dir)
       when is_binary(socket) and is_binary(data_dir) do
    socket = Path.expand(socket)
    data_dir = Path.expand(data_dir)
    socket != data_dir and not String.starts_with?(socket, data_dir <> "/")
  end

  defp socket_outside_data_dir?(_, _), do: false
end
