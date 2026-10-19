Tay.Test.Environment.validate!()

Application.put_env(:phoenix, Tay.Dashboard.TestEndpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "tay-dashboard-test"],
  pubsub_server: Tay.Dashboard.TestPubSub,
  server: false
)

ExUnit.start()
