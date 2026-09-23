import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]

config :tay_dashboard_standalone, Tay.Dashboard.Standalone.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Tay.Dashboard.Standalone.PubSub,
  live_view: [signing_salt: "tay-dashboard-live"],
  render_errors: [
    formats: [html: Tay.Dashboard.Standalone.ErrorHTML],
    layout: false
  ],
  server: false

import_config "#{config_env()}.exs"
