defmodule Tay.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.6.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ],
      dialyzer: [
        plt_add_apps: [:mix],
        paths: [
          "_build/#{Mix.env()}/lib/tay/ebin",
          "_build/#{Mix.env()}/lib/tay_http/ebin",
          "_build/#{Mix.env()}/lib/tay_dashboard/ebin"
        ]
      ],
      aliases: [quality: ["format --check-formatted", "compile --warnings-as-errors", "test"]]
    ]
  end
end
