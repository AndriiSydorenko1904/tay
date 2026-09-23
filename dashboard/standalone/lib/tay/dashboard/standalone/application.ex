defmodule Tay.Dashboard.Standalone.Application do
  @moduledoc false

  use Application

  alias Tay.Dashboard.Standalone.{Config, Endpoint}

  @impl true
  def start(_type, _args) do
    environment =
      Application.get_env(:tay_dashboard_standalone, :environment, System.get_env())

    with {:ok, config} <- Config.load(environment) do
      configure_endpoint(config)

      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: Tay.Dashboard.Standalone.PubSub},
          Endpoint
        ],
        strategy: :one_for_one,
        name: Tay.Dashboard.Standalone.Supervisor
      )
    else
      {:error, message} -> {:error, {:invalid_dashboard_configuration, message}}
    end
  end

  @impl true
  def config_change(changed, removed, _extra), do: Endpoint.config_change(changed, removed)

  defp configure_endpoint(config) do
    existing = Application.get_env(:tay_dashboard_standalone, Endpoint, [])

    runtime = [
      server: Application.get_env(:tay_dashboard_standalone, :serve, true),
      url: [host: config.host, port: config.port],
      http: [ip: {0, 0, 0, 0}, port: config.port],
      check_origin: ["//#{config.host}"],
      secret_key_base: config.secret_key_base
    ]

    Application.put_env(:tay_dashboard_standalone, Endpoint, Keyword.merge(existing, runtime))

    if config.username do
      Application.put_env(:tay_dashboard_standalone, :basic_auth, %{
        username: config.username,
        password: config.password
      })
    else
      Application.delete_env(:tay_dashboard_standalone, :basic_auth)
    end
  end
end
