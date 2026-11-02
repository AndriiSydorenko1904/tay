[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "bench/upgrade-drill.exs",
    "{config,lib,mix_helpers,test}/**/*.{ex,exs,heex}"
  ]
]
