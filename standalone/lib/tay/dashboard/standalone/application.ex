defmodule Tay.Dashboard.Standalone.Application do
  @moduledoc false

  alias Tay.Dashboard.Standalone.{Config, Endpoint}

  def children(environment) do
    case Config.enabled(environment) do
      {:ok, false} ->
        {:ok, []}

      {:ok, true} ->
        with {:ok, config} <- Config.load(environment) do
          configure_endpoint(config)

          {:ok, [{Phoenix.PubSub, name: Tay.Dashboard.Standalone.PubSub}, Endpoint]}
        else
          {:error, message} -> {:error, {:invalid_dashboard_configuration, message}}
        end

      {:error, message} ->
        {:error, {:invalid_dashboard_configuration, message}}
    end
  end

  def config_change(changed, removed, _extra), do: Endpoint.config_change(changed, removed)

  defp configure_endpoint(config) do
    existing = Application.get_env(:tay_standalone, Endpoint, [])

    runtime = [
      server: Application.get_env(:tay_standalone, :serve, true),
      url: [host: config.host, port: config.port],
      http: [ip: {0, 0, 0, 0}, port: config.port],
      # Compare the Origin header with the actual request authority. This keeps
      # same-origin protection while supporting Docker port publishing and
      # trusted reverse proxies whose public port differs from the listener.
      check_origin: :conn,
      secret_key_base: config.secret_key_base
    ]

    Application.put_env(:tay_standalone, Endpoint, Keyword.merge(existing, runtime))

    if config.username do
      Application.put_env(:tay_standalone, :basic_auth, %{
        username: config.username,
        password: config.password
      })
    else
      Application.delete_env(:tay_standalone, :basic_auth)
    end
  end
end
