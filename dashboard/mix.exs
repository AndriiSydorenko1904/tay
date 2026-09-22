defmodule TayDashboard.MixProject do
  use Mix.Project

  @version "0.8.1"
  @source_url "https://github.com/AndriiSydorenko1904/tay"

  def project do
    [
      app: :tay_dashboard,
      version: @version,
      description: "Official optional Phoenix LiveView dashboard for Tay",
      source_url: @source_url,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: [main: "readme", source_ref: "v#{@version}", extras: ["README.md"]]
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
      {:floki, ">= 0.38.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false}
    ]
  end

  defp tay_dependency do
    if System.get_env("TAY_DASHBOARD_PACKAGE") == "1",
      do: {:tay, "~> 0.8.1"},
      else: {:tay, "~> 0.8.1", path: "..", override: true, env: Mix.env()}
  end

  defp package do
    [
      name: "tay_dashboard",
      files: ["lib", "mix.exs", ".formatter.exs", "README.md", "LICENSE"],
      build_tools: ["mix"],
      licenses: ["Elastic-2.0"],
      links: %{"Source" => @source_url, "Tay" => "https://hex.pm/packages/tay"}
    ]
  end
end
