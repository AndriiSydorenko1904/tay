defmodule Mix.Tasks.Compile.TayNative do
  use Mix.Task.Compiler
  import Bitwise
  @impl true
  def run(_args) do
    cc =
      System.find_executable("cc") || Mix.raise("A C compiler is required for Tay's storage Port")

    dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(dir)

    # A reused build directory must not leak the generated fault-enabled helper
    # into a production artifact. This exact output is recreated by test builds.
    if Mix.env() != :test do
      case File.rm(Path.join(dir, "tay_storage_helper_test")) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _} -> Mix.raise("Cannot remove stale generated test helper from build output")
      end
    end

    builds =
      if Mix.env() == :test,
        do: [{"tay_storage_helper", []}, {"tay_storage_helper_test", ["-DTAY_TEST_FAULTS"]}],
        else: [{"tay_storage_helper", []}]

    Enum.each(builds, fn {name, defines} ->
      sanitizer =
        if System.get_env("TAY_NATIVE_SANITIZE") == "1",
          do: ["-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-g"],
          else: []

      args =
        ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Wformat=2"] ++
          sanitizer ++
          defines ++ ["c_src/tay_storage_helper.c", "-o", Path.join(dir, name)]

      case System.cmd(cc, args, stderr_to_stdout: true) do
        {_, 0} ->
          artifact = Path.join(dir, name)
          stat = File.stat!(artifact)

          unless stat.type == :regular and (stat.mode &&& 0o111) != 0,
            do: Mix.raise("Native compiler did not produce an executable regular helper")

        {output, code} ->
          Mix.raise("Native helper compilation failed (#{code}):\n#{output}")
      end
    end)

    {:ok, []}
  end
end

defmodule Tay.MixProject do
  use Mix.Project
  @version "0.8.0"
  @source_url "https://github.com/AndriiSydorenko1904/tay"

  def project do
    [
      app: :tay,
      version: @version,
      description: "Public-preview single-node durable job engine with fail-closed recovery",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:tay_native] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: [
        {:telemetry, "~> 1.3"},
        {:stream_data, "~> 1.2", only: :test},
        {:ex_doc, "~> 0.40.4", only: :dev, runtime: false}
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
        "c_src/tay_storage_helper.c",
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
        "docs/tay-dashboard-design.md"
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
        "docs/tay-dashboard-design.md"
      ]
    ]
  end
end
