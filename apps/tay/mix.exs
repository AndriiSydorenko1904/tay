defmodule Mix.Tasks.Compile.TayNative do
  use Mix.Task.Compiler
  import Bitwise

  @impl true
  def run(_args) do
    if Mix.Project.config()[:apps_path] do
      {:noop, []}
    else
      compile_native()
    end
  end

  defp compile_native do
    cc =
      System.find_executable("cc") || Mix.raise("A C compiler is required for Tay's storage Port")

    dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(dir)

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
          sanitizer ++ defines ++ ["c_src/tay_storage_helper.c", "-o", Path.join(dir, name)]

      case System.cmd(cc, args, stderr_to_stdout: true) do
        {_, 0} ->
          stat = File.stat!(Path.join(dir, name))

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
  @version "1.6.0"
  @source_url "https://github.com/AndriiSydorenko1904/tay"
  @umbrella_root Path.expand("../..", __DIR__)

  def project do
    [
      app: :tay,
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
         File.regular?(Path.join(@umbrella_root, "apps/tay_dashboard/mix.exs")) do
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
      name: "tay",
      files: ["lib", "c_src", "mix.exs", "README.md"],
      build_tools: ["mix"],
      links: %{"Source" => @source_url},
      licenses: ["Elastic-2.0"]
    ]
end
