defmodule Tay.MixProject do
  use Mix.Project

  def project do
    [
      app: :tay,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: [{:stream_data, "~> 1.2", only: :test}]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Tay.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
