import Config

# Tay's dependency application performs configuration validation only; dashboard
# tests start explicit disposable engines with their own data directories.
if config_env() in [:dev, :test] do
  config :tay, data_dir: Path.expand("../tmp/dashboard-foundation", __DIR__)
end
