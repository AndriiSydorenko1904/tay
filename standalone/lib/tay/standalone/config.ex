defmodule Tay.Standalone.Config do
  @moduledoc false

  @data_default "/var/lib/tay"
  @socket_default "/run/tay/tay.sock"

  defstruct data_dir: @data_default,
            socket_path: @socket_default,
            http_port: nil,
            http_ip: "127.0.0.1",
            http_tls_certfile: nil,
            http_tls_keyfile: nil,
            http_tls_cacertfile: nil,
            initialize: :never,
            max_state_bytes: 268_435_456,
            max_state_nodes: 2_000_000,
            terminal_retention: {:hours, 24}

  @type t :: %__MODULE__{
          data_dir: String.t(),
          socket_path: nil | String.t(),
          http_port: nil | pos_integer(),
          http_ip: String.t(),
          http_tls_certfile: nil | String.t(),
          http_tls_keyfile: nil | String.t(),
          http_tls_cacertfile: nil | String.t(),
          initialize: :never | :if_missing,
          max_state_bytes: non_neg_integer(),
          max_state_nodes: non_neg_integer(),
          terminal_retention: {:minutes, pos_integer()} | {:hours, pos_integer()}
        }

  @spec load(map()) :: {:ok, t()} | {:error, String.t()}
  def load(environment \\ System.get_env())

  def load(environment) when is_map(environment) do
    with {:ok, data_dir} <- path(environment, "TAY_DATA_DIR", @data_default, :data),
         {:ok, socket_path} <- socket_path(environment),
         :ok <- outside_data_dir(socket_path, data_dir),
         :ok <- legacy_grpc_environment(environment),
         {:ok, http_port} <- optional_port(environment),
         {:ok, http_ip} <- http_ip(environment),
         {:ok, tls} <- http_tls(environment),
         :ok <- validate_http(http_port, http_ip, tls),
         :ok <- require_transport(socket_path, http_port),
         {:ok, initialize} <- initialize(environment),
         {:ok, max_state_bytes} <-
           nonnegative(environment, "TAY_MAX_STATE_BYTES", 268_435_456),
         {:ok, max_state_nodes} <-
           nonnegative(environment, "TAY_MAX_STATE_NODES", 2_000_000),
         {:ok, terminal_retention} <- terminal_retention(environment) do
      {:ok,
       %__MODULE__{
         data_dir: data_dir,
         socket_path: socket_path,
         http_port: http_port,
         http_ip: http_ip,
         http_tls_certfile: tls.certfile,
         http_tls_keyfile: tls.keyfile,
         http_tls_cacertfile: tls.cacertfile,
         initialize: initialize,
         max_state_bytes: max_state_bytes,
         max_state_nodes: max_state_nodes,
         terminal_retention: terminal_retention
       }}
    end
  end

  def load(_), do: {:error, "environment must be a string map"}

  defp legacy_grpc_environment(environment) do
    if Enum.any?(Map.keys(environment), fn key ->
         is_binary(key) and String.starts_with?(key, "TAY_GRPC_")
       end),
       do: {:error, "TAY_GRPC_* is unsupported; use TAY_HTTP_* for the Bandit HTTP API"},
       else: :ok
  end

  defp optional_port(environment) do
    case Map.get(environment, "TAY_HTTP_PORT", "") do
      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 -> {:ok, port}
          _ -> {:error, "TAY_HTTP_PORT must be a TCP port from 1 to 65535"}
        end

      _ ->
        {:error, "TAY_HTTP_PORT must be a TCP port from 1 to 65535"}
    end
  end

  defp http_ip(environment) do
    ip = Map.get(environment, "TAY_HTTP_IP", "127.0.0.1")

    if is_binary(ip) and match?({:ok, _}, :inet.parse_address(String.to_charlist(ip))),
      do: {:ok, ip},
      else: {:error, "TAY_HTTP_IP must be an IP address"}
  end

  defp http_tls(environment) do
    names = ["TAY_HTTP_TLS_CERTFILE", "TAY_HTTP_TLS_KEYFILE", "TAY_HTTP_TLS_CACERTFILE"]
    values = Enum.map(names, &Map.get(environment, &1, ""))

    cond do
      Enum.all?(values, &(&1 == "")) ->
        {:ok, %{certfile: nil, keyfile: nil, cacertfile: nil}}

      Enum.all?(values, &(is_binary(&1) and &1 != "" and Path.type(&1) == :absolute)) ->
        [certfile, keyfile, cacertfile] = values
        {:ok, %{certfile: certfile, keyfile: keyfile, cacertfile: cacertfile}}

      true ->
        {:error,
         "TAY_HTTP_TLS_CERTFILE, TAY_HTTP_TLS_KEYFILE and TAY_HTTP_TLS_CACERTFILE must all be absolute paths"}
    end
  end

  defp validate_http(port, ip, tls) do
    secured = not is_nil(tls.certfile)

    loopback =
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, {127, _, _, _}} -> true
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
        _ -> false
      end

    cond do
      is_nil(port) and secured ->
        {:error, "TAY_HTTP_PORT is required when HTTP TLS is configured"}

      not is_nil(port) and not loopback and not secured ->
        {:error, "non-loopback TAY_HTTP_IP requires all three HTTP TLS files"}

      true ->
        :ok
    end
  end

  defp path(environment, name, default, kind) do
    value = Map.get(environment, name, default)

    cond do
      not is_binary(value) ->
        {:error, "#{name} must be a path string"}

      not String.valid?(value) ->
        {:error, "#{name} must contain valid UTF-8"}

      String.trim(value) == "" ->
        {:error, "#{name} must not be blank"}

      String.contains?(value, <<0>>) ->
        {:error, "#{name} must not contain NUL bytes"}

      Path.type(value) != :absolute ->
        {:error, "#{name} must be an absolute path"}

      kind == :socket and byte_size(value) > 100 ->
        {:error, "#{name} must be at most 100 bytes"}

      true ->
        {:ok, Path.expand(value)}
    end
  end

  defp socket_path(environment) do
    case Map.get(environment, "TAY_SOCKET_PATH", @socket_default) do
      "off" -> {:ok, nil}
      _ -> path(environment, "TAY_SOCKET_PATH", @socket_default, :socket)
    end
  end

  defp require_transport(nil, nil), do: {:error, "enable TAY_HTTP_PORT when TAY_SOCKET_PATH=off"}
  defp require_transport(_, _), do: :ok

  defp outside_data_dir(nil, _data_dir), do: :ok

  defp outside_data_dir(socket_path, data_dir) do
    if socket_path == data_dir or String.starts_with?(socket_path, data_dir <> "/") do
      {:error, "TAY_SOCKET_PATH must be outside TAY_DATA_DIR"}
    else
      :ok
    end
  end

  defp initialize(environment) do
    case Map.get(environment, "TAY_INITIALIZE_IF_MISSING", "false") do
      value when value in ["true", "TRUE", "1"] ->
        {:ok, :if_missing}

      value when value in ["false", "FALSE", "0"] ->
        {:ok, :never}

      value ->
        {:error,
         "TAY_INITIALIZE_IF_MISSING must be one of true, false, TRUE, FALSE, 1, or 0; got: #{inspect(value)}"}
    end
  end

  defp nonnegative(environment, name, default) do
    case Map.get(environment, name, Integer.to_string(default)) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} when number >= 0 -> {:ok, number}
          _ -> {:error, "#{name} must be a non-negative integer"}
        end

      _ ->
        {:error, "#{name} must be a non-negative integer"}
    end
  end

  defp terminal_retention(environment) do
    value = Map.get(environment, "TAY_TERMINAL_RETENTION", "24h")

    with value when is_binary(value) <- value,
         [_, amount, unit] <- Regex.run(~r/\A([1-9][0-9]*)(m|h|d)\z/, value),
         {amount, ""} <- Integer.parse(amount),
         retention <- retention(amount, unit),
         :ok <- Tay.Storage.V2.Retention.validate(retention) do
      {:ok, retention}
    else
      _ ->
        {:error,
         "TAY_TERMINAL_RETENTION must use a positive duration such as 30m, 1h, 24h, or 7d"}
    end
  end

  defp retention(amount, "m"), do: {:minutes, amount}
  defp retention(amount, "h"), do: {:hours, amount}
  defp retention(amount, "d"), do: {:hours, amount * 24}
end
