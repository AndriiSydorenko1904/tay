Code.require_file("mix_helpers/tay_native.exs", __DIR__)
Code.require_file("mix_helpers/tay_native_editor.exs", __DIR__)

defmodule Tay.MixProject do
  use Mix.Project
  @version "1.8.0-rc1"
  @source_url "https://github.com/AndriiSydorenko1904/tay"

  def project do
    [
      app: :tay,
      version: @version,
      description: "Single-node durable job engine with fail-closed recovery",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:tay_native] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      deps: [
        {:telemetry, "~> 1.3"},
        {:telemetry_metrics, "~> 1.1"},
        {:bandit, "~> 1.14"},
        {:phoenix, "~> 1.8.14"},
        {:phoenix_live_view, "~> 1.2.11"},
        {:phoenix_html, "~> 4.3"},
        {:jason, "~> 1.4"},
        {:floki, ">= 0.38.0", only: :test},
        {:lazy_html, ">= 0.1.0", only: :test},
        {:stream_data, "~> 1.2", only: :test},
        {:telemetry_metrics_prometheus_core, "~> 1.2", only: :test},
        {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Tay.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      name: "tay",
      # Native code is compiled for the consuming build host. Never distribute
      # this checkout's priv binaries, test providers, local configuration or data.
      files: [
        "lib",
        "mix_helpers/tay_native.exs",
        "mix_helpers/tay_native_editor.exs",
        "c_src/tay_storage_helper.c",
        "c_src/tay_crc32c.c",
        "c_src/README.md",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "COMMERCIAL-LICENSING.md",
        "docs/protocol.md",
        "docs/storage.md",
        "docs/operations.md",
        "docs/compatibility.md",
        "docs/idempotency.md",
        "docs/standalone.md",
        "docs/dashboard.md",
        "docs/dashboard-container.md",
        "docs/observability.md"
      ],
      build_tools: ["mix"],
      links: %{
        "Source" => @source_url,
        "Documentation" => @source_url <> "/tree/v#{@version}/docs"
      },
      licenses: ["Elastic-2.0"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "COMMERCIAL-LICENSING.md",
        "docs/protocol.md",
        "docs/storage.md",
        "docs/operations.md",
        "docs/compatibility.md",
        "docs/idempotency.md",
        "docs/standalone.md",
        "docs/dashboard.md",
        "docs/dashboard-container.md",
        "docs/observability.md"
      ]
    ]
  end
end
