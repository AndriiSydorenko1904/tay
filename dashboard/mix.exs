defmodule TayDashboard.MixProject do
  use Mix.Project

  @version "0.11.0"
  @tay_requirement ">= 0.9.6 and < 0.12.0"
  @source_url "https://github.com/AndriiSydorenko1904/tay"

  def project do
    [
      app: :tay_dashboard,
      version: @version,
      description: "Official optional Phoenix LiveView dashboard for Tay",
      source_url: @source_url,
      elixir: "~> 1.20",
      lockfile: lockfile(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md", "guides/docker.md", "guides/documentation.md"],
        groups_for_extras: [
          Deployment: ["guides/docker.md"],
          Development: ["guides/documentation.md"]
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      tay_dependency(),
      {:phoenix, "~> 1.8.14"},
      {:phoenix_live_view, "~> 1.2.11"},
      {:phoenix_html, "~> 4.3"},
      {:jason, "~> 1.4"},
      {:floki, ">= 0.38.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false}
    ]
  end

  defp tay_dependency do
    if package_mode?(),
      do: {:tay, @tay_requirement},
      else: {:tay, @tay_requirement, path: "..", override: true, env: Mix.env()}
  end

  defp lockfile, do: if(package_mode?(), do: "mix.package.lock", else: "mix.lock")
  defp package_mode?, do: System.get_env("TAY_DASHBOARD_PACKAGE") == "1"

  defp package do
    [
      name: "tay_dashboard",
      files: ["lib", "guides", "mix.exs", ".formatter.exs", "README.md", "LICENSE"],
      build_tools: ["mix"],
      licenses: ["Elastic-2.0"],
      links: %{"Source" => @source_url, "Tay" => "https://hex.pm/packages/tay"}
    ]
  end
end
