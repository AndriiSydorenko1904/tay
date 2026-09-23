defmodule TayDashboardStandalone.MixProject do
  use Mix.Project

  @root Path.expand("../..", __DIR__)
  @dashboard_root Path.expand("..", __DIR__)
  @version (case Regex.run(~r/@version\s+"([^"]+)"/, File.read!(Path.join(@root, "mix.exs")),
                   capture: :all_but_first
                 ) do
              [version] -> version
              _ -> raise "cannot read Tay version from #{@root}/mix.exs"
            end)
  @dashboard_version (case Regex.run(
                             ~r/@version\s+"([^"]+)"/,
                             File.read!(Path.join(@dashboard_root, "mix.exs")),
                             capture: :all_but_first
                           ) do
                        [version] -> version
                        _ -> raise "cannot read Tay Dashboard version"
                      end)

  if @dashboard_version != @version do
    raise "Tay #{@version} and Tay Dashboard #{@dashboard_version} cannot share one image"
  end

  def project do
    [
      app: :tay_dashboard_standalone,
      version: @version,
      elixir: "~> 1.20",
      elixirc_options: [debug_info: false],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [tay_dashboard_standalone: [applications: [runtime_tools: :permanent]]]
    ]
  end

  def application do
    [
      mod: {Tay.Dashboard.Standalone.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:tay_standalone, path: "../../standalone"},
      {:tay_dashboard, path: ".."},
      {:bandit, "~> 1.8"}
    ]
  end
end
