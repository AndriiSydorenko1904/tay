defmodule TayHTTP.MixProject do
  use Mix.Project
  @version "1.6.0"
  @source_url "https://github.com/AndriiSydorenko1904/tay"
  @umbrella_root Path.expand("../..", __DIR__)
  def project,
    do:
      [
        app: :tay_http,
        version: @version,
        description: "Bandit HTTP transport for Tay",
        source_url: @source_url,
        package: package(),
        docs: [main: "readme", source_ref: "v#{@version}", extras: ["README.md"]],
        elixir: "~> 1.20",
        deps: deps()
      ] ++ umbrella_paths()

  def application, do: [extra_applications: [:logger]]

  defp deps,
    do: [
      tay_dependency(),
      {:bandit, "~> 1.13"},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]

  defp tay_dependency do
    if System.get_env("TAY_HEX_BUILD") == "1" or not umbrella_checkout?(),
      do: {:tay, "~> 1.6"},
      else: {:tay, "~> 1.6", in_umbrella: true}
  end

  defp umbrella_paths do
    if umbrella_checkout?() do
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

  defp umbrella_checkout? do
    File.regular?(Path.join(@umbrella_root, "apps/tay/mix.exs")) and
      File.regular?(Path.join(@umbrella_root, "apps/tay_dashboard/mix.exs"))
  end

  defp package,
    do: [
      name: "tay_http",
      files: ["lib", "mix.exs", "README.md"],
      build_tools: ["mix"],
      links: %{"Source" => @source_url},
      licenses: ["Elastic-2.0"]
    ]
end
