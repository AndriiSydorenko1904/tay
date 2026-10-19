Code.require_file("mix_helpers/tay_native.exs", __DIR__)

defmodule TayCore.MixProject do
  use Mix.Project
  @version "1.6.1"
  @source_url "https://github.com/AndriiSydorenko1904/tay"
  @umbrella_root Path.expand("../..", __DIR__)

  def project do
    [
      app: :tay_core,
      version: @version,
      description: "Single-node durable job engine with fail-closed recovery",
      source_url: @source_url,
      package: package(),
      docs: [main: "readme", source_ref: "v#{@version}", extras: ["README.md"]],
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:tay_native] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      dialyzer: [plt_add_apps: [:mix]],
      deps: deps()
    ] ++ umbrella_paths()
  end

  def application, do: [extra_applications: [:logger, :crypto], mod: {Tay.Application, []}]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps,
    do: [
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:stream_data, "~> 1.2", only: :test},
      {:telemetry_metrics_prometheus_core, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]

  defp umbrella_paths do
    if File.regular?(Path.join(@umbrella_root, "apps/tay_http/mix.exs")) and
         File.regular?(Path.join(@umbrella_root, "apps/tay/mix.exs")) do
      [
        build_path: Path.join(@umbrella_root, "_build"),
        config_path: Path.join(@umbrella_root, "config/config.exs"),
        deps_path: Path.join(@umbrella_root, "deps"),
        lockfile: Path.join(@umbrella_root, "mix.lock")
      ]
    else
      []
    end
  end

  defp package,
    do: [
      name: "tay_core",
      files: ["lib", "c_src", "mix_helpers", "mix.exs", "README.md"],
      build_tools: ["mix"],
      links: %{"Source" => @source_url},
      licenses: ["Elastic-2.0"]
    ]
end
