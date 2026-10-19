import Config

flavor =
  case System.get_env("TAY_STANDALONE_FLAVOR", "dashboard") do
    "core" -> :core
    "http" -> :http
    "dashboard" -> :dashboard
    value -> raise "unsupported TAY_STANDALONE_FLAVOR: #{inspect(value)}"
  end

config :tay_standalone, flavor: flavor

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]

if flavor == :dashboard do
  config :tay_standalone, Tay.Dashboard.Standalone.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    pubsub_server: Tay.Dashboard.Standalone.PubSub,
    live_view: [signing_salt: "tay-dashboard-live"],
    render_errors: [
      formats: [html: Tay.Dashboard.Standalone.ErrorHTML],
      layout: false
    ],
    server: false
end

import_config "#{config_env()}.exs"
