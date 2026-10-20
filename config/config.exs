import Config

# Provisional paths for developing this repository, not production defaults.
if config_env() in [:dev, :test] do
  config :tay, data_dir: "var/tay/#{config_env()}"
end
