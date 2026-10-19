defmodule TayStandalone.MixProject do
  use Mix.Project

  @root Path.expand("..", __DIR__)
  @core Path.join(@root, "apps/tay")
  @version (case Regex.run(~r/@version\s+"([^"]+)"/, File.read!(Path.join(@core, "mix.exs")),
                   capture: :all_but_first
                 ) do
              [version] -> version
              _ -> raise "cannot read Tay version from #{@core}/mix.exs"
            end)

  def project do
    [
      app: :tay_standalone,
      version: @version,
      elixir: "~> 1.20",
      elixirc_options: [debug_info: false],
      start_permanent: Mix.env() == :prod,
      deps: [
        {:tay, "~> 1.6", path: Path.join(@root, "apps/tay"), override: true},
        {:tay_http, path: Path.join(@root, "apps/tay_http")},
        {:tay_dashboard, path: Path.join(@root, "apps/tay_dashboard")},
        {:jason, "~> 1.4"}
      ],
      releases: [tay_standalone: [applications: [runtime_tools: :permanent]]]
    ]
  end

  def application do
    [
      mod: {Tay.Standalone.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end
end
