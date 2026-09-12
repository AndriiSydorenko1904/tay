defmodule Mix.Tasks.Compile.TayNative do
  use Mix.Task.Compiler
  @impl true
  def run(_args) do
    cc =
      System.find_executable("cc") || Mix.raise("A C compiler is required for Tay's storage Port")

    dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(dir)

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
        {_, 0} -> :ok
        {output, code} -> Mix.raise("Native helper compilation failed (#{code}):\n#{output}")
      end
    end)

    {:ok, []}
  end
end

defmodule Tay.MixProject do
  use Mix.Project

  def project do
    [
      app: :tay,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:tay_native] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: [{:stream_data, "~> 1.2", only: :test}]
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
end
