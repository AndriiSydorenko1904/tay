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
      elixirc_paths: elixirc_paths(flavor()),
      start_permanent: Mix.env() == :prod,
      deps: deps(flavor()),
      releases: [tay_standalone: [applications: [runtime_tools: :permanent]]]
    ]
  end

  def application do
    [
      mod: {Tay.Standalone.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp flavor do
    case System.get_env("TAY_STANDALONE_FLAVOR", "dashboard") do
      "core" -> :core
      "http" -> :http
      "dashboard" -> :dashboard
      value -> raise "unsupported TAY_STANDALONE_FLAVOR: #{inspect(value)}"
    end
  end

  defp deps(:core), do: [{:tay, path: Path.join(@root, "apps/tay")}]
  defp deps(:http), do: [{:tay_http, path: Path.join(@root, "apps/tay_http")}]

  defp deps(:dashboard),
    do: [
      {:tay_dashboard, path: Path.join(@root, "apps/tay_dashboard")},
      {:jason, "~> 1.4"}
    ]

  defp elixirc_paths(:dashboard), do: ["lib/tay/standalone", "lib/tay/dashboard"]
  defp elixirc_paths(_flavor), do: ["lib/tay/standalone"]
end
