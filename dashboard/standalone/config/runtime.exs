import Config

# Tay's foundation application starts before either standalone host, so make
# the configured Store root visible before the Engine is supervised.
config :tay,
  data_dir: System.get_env("TAY_DATA_DIR", "/var/lib/tay"),
  queues: [default: 10]
