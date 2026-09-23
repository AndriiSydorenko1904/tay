import Config

# Tay's foundation application starts before the standalone host, so publish
# the storage location here. Full standalone validation still happens in the
# host before it starts the Engine or touches storage.
config :tay,
  data_dir: System.get_env("TAY_DATA_DIR", "/var/lib/tay"),
  queues: [default: 10]
