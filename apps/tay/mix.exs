defmodule Tay.MixProject do
  use Mix.Project
  @version "1.6.1"
  @source_url "https://github.com/AndriiSydorenko1904/tay"
  @umbrella_root Path.expand("../..", __DIR__)
  def project,
    do:
      [
        app: :tay,
        version: @version,
        description: "Phoenix LiveView dashboard and HTTP bundle for Tay",
        source_url: @source_url,
        package: package(),
        docs: [main: "readme", source_ref: "v#{@version}", extras: ["README.md"]],
        elixir: "~> 1.20",
        elixirc_paths: elixirc_paths(Mix.env()),
        deps: deps()
      ] ++ umbrella_paths()

  def application, do: [extra_applications: [:logger]]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps,
    do: [
      http_dependency(),
      {:phoenix, "~> 1.8.14"},
      {:phoenix_live_view, "~> 1.2.11"},
      {:phoenix_html, "~> 4.3"},
      {:floki, ">= 0.38.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]

  defp http_dependency do
    if System.get_env("TAY_HEX_BUILD") == "1" or not umbrella_checkout?(),
      do: {:tay_http, "~> 1.6"},
      else: {:tay_http, "~> 1.6", in_umbrella: true}
  end

  defp umbrella_paths do
    case {System.get_env("TAY_HEX_BUILD"), System.get_env("TAY_HEX_WORKSPACE")} do
      {"1", workspace} when is_binary(workspace) ->
        isolated_hex_paths(workspace)

      _ ->
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
  end

  defp isolated_hex_paths(workspace) do
    workspace = Path.expand(workspace)

    [
      build_path: Path.join(workspace, "build"),
      deps_path: Path.join(workspace, "deps"),
      lockfile: Path.join(workspace, "mix.lock")
    ]
  end

  defp umbrella_checkout? do
    File.regular?(Path.join(@umbrella_root, "apps/tay_core/mix.exs")) and
      File.regular?(Path.join(@umbrella_root, "apps/tay_http/mix.exs"))
  end

  defp package,
    do: [
      name: "tay",
      files: ["lib", "mix.exs", "README.md"],
      build_tools: ["mix"],
      links: %{"Source" => @source_url},
      licenses: ["Elastic-2.0"]
    ]
end
