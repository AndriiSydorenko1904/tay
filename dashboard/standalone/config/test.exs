import Config

config :logger, level: :warning
config :tay_standalone, start_runtime: false
config :tay_dashboard_standalone, serve: false

config :tay_dashboard_standalone,
  environment: %{
    "TAY_DASHBOARD_HOST" => "localhost",
    "TAY_DASHBOARD_PORT" => "4002",
    "TAY_DASHBOARD_USERNAME" => "admin",
    "TAY_DASHBOARD_PASSWORD" => "test-password",
    "TAY_DASHBOARD_SECRET_KEY_BASE" => String.duplicate("t", 64)
  }
