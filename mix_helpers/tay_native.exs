defmodule Mix.Tasks.Compile.TayNative do
  use Mix.Task.Compiler
  import Bitwise

  @source Path.expand("../c_src/tay_storage_helper.c", __DIR__)

  @impl Mix.Task.Compiler
  def run(_args) do
    if Mix.Project.config()[:app] == :tay, do: compile_native(), else: {:noop, []}
  end

  defp compile_native do
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
          sanitizer ++ defines ++ [@source, "-o", Path.join(dir, name)]

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
