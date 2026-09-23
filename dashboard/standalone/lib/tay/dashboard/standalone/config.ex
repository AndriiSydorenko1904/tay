defmodule Tay.Dashboard.Standalone.Config do
  @moduledoc false

  @default_host "localhost"
  @default_port 4000

  defstruct [:host, :port, :username, :password, :secret_key_base]

  @type t :: %__MODULE__{
          host: String.t(),
          port: :inet.port_number(),
          username: String.t() | nil,
          password: String.t() | nil,
          secret_key_base: String.t()
        }

  @spec load(map()) :: {:ok, t()} | {:error, String.t()}
  def load(environment \\ System.get_env())

  def load(environment) when is_map(environment) do
    with {:ok, host} <- required_or_default(environment, "TAY_DASHBOARD_HOST", @default_host),
         :ok <- validate_host(host),
         {:ok, port} <- port(Map.get(environment, "TAY_DASHBOARD_PORT", "#{@default_port}")),
         {:ok, {username, password}} <- credentials(environment),
         {:ok, secret} <- required(environment, "TAY_DASHBOARD_SECRET_KEY_BASE"),
         :ok <- validate_secret(secret) do
      {:ok,
       %__MODULE__{
         host: host,
         port: port,
         username: username,
         password: password,
         secret_key_base: secret
       }}
    end
  end

  def load(_), do: {:error, "environment must be a string map"}

  defp required(environment, name) do
    case Map.get(environment, name) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, "#{name} must not be blank"},
          else: {:ok, value}

      _ ->
        {:error, "#{name} is required"}
    end
  end

  defp credentials(environment) do
    username = Map.get(environment, "TAY_DASHBOARD_USERNAME")
    password = Map.get(environment, "TAY_DASHBOARD_PASSWORD")

    case {username, password} do
      {nil, nil} ->
        {:ok, {nil, nil}}

      {username, password} when is_binary(username) and is_binary(password) ->
        if String.trim(username) == "" or String.trim(password) == "" do
          {:error,
           "TAY_DASHBOARD_USERNAME and TAY_DASHBOARD_PASSWORD must both be nonblank when Basic Auth is enabled"}
        else
          {:ok, {username, password}}
        end

      _ ->
        {:error,
         "TAY_DASHBOARD_USERNAME and TAY_DASHBOARD_PASSWORD must be provided together to enable Basic Auth"}
    end
  end

  defp required_or_default(environment, name, default) do
    case Map.get(environment, name, default) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, "#{name} must not be blank"},
          else: {:ok, value}

      _ ->
        {:error, "#{name} must be a string"}
    end
  end

  defp validate_host(host) do
    if not String.match?(host, ~r/^[A-Za-z0-9.-]+$/),
      do: {:error, "TAY_DASHBOARD_HOST must be a hostname without a scheme, port, or path"},
      else: :ok
  end

  defp port(value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> {:error, "TAY_DASHBOARD_PORT must be an integer from 1 through 65535"}
    end
  end

  defp port(_), do: {:error, "TAY_DASHBOARD_PORT must be a string integer"}

  defp validate_secret(secret) do
    if byte_size(secret) >= 64,
      do: :ok,
      else: {:error, "TAY_DASHBOARD_SECRET_KEY_BASE must contain at least 64 bytes"}
  end
end
