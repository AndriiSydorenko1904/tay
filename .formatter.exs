[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "mix_helpers/**/*.{ex,exs}",
    "config/**/*.{ex,exs}",
    "apps/*/{mix,.formatter}.exs",
    "apps/*/mix_helpers/**/*.{ex,exs}",
    "apps/*/{lib,test}/**/*.{ex,exs,heex}",
    "standalone/{mix,.formatter}.exs",
    "standalone/{config,lib,test}/**/*.{ex,exs,heex}"
  ]
]
