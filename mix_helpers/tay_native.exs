defmodule Mix.Tasks.Compile.TayNative do
  use Mix.Task.Compiler
  import Bitwise

  @source Path.expand("../c_src/tay_storage_helper.c", __DIR__)
  @crc_source Path.expand("../c_src/tay_crc32c.c", __DIR__)
  @common_flags ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Wformat=2"]

  @impl Mix.Task.Compiler
  def run(_args) do
    if Mix.Project.config()[:app] == :tay, do: compile_native(), else: {:noop, []}
  end

  defp compile_native do
    cc = compiler!()

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
      flags = helper_flags() ++ defines
      args = flags ++ [@source, "-o", Path.join(dir, name)]

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

    compile_crc32c(cc, dir)
    {:ok, []}
  end

  defp compile_crc32c(cc, dir) do
    artifact = Path.join(dir, "tay_crc32c.so")

    linker =
      case :os.type() do
        {:unix, :darwin} -> ["-dynamiclib", "-undefined", "dynamic_lookup"]
        {:unix, :linux} -> ["-shared"]
        platform -> Mix.raise("Unsupported platform for Tay CRC32C NIF: #{inspect(platform)}")
      end

    flags = crc_flags()

    args = flags ++ linker ++ [@crc_source, "-o", artifact]

    case System.cmd(cc, args, stderr_to_stdout: true) do
      {_, 0} ->
        unless File.regular?(artifact), do: Mix.raise("CRC32C compiler did not produce a library")

      {output, code} ->
        Mix.raise("CRC32C NIF compilation failed (#{code}):\n#{output}")
    end
  end

  @doc false
  def compilation_commands do
    cc = compiler!()

    for {source, flags} <- [{@source, helper_flags()}, {@crc_source, crc_flags()}] do
      # Preprocessing queries need compilation flags, without linker-only options.
      %{directory: File.cwd!(), file: source, arguments: [cc | flags] ++ ["-c", source]}
    end
  end

  @doc false
  def erlang_include, do: Path.join([List.to_string(:code.root_dir()), "usr", "include"])

  defp compiler! do
    System.find_executable("cc") || Mix.raise("A C compiler is required for Tay's native code")
  end

  defp helper_flags do
    sanitizer =
      if System.get_env("TAY_NATIVE_SANITIZE") == "1",
        do: ["-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-g"],
        else: []

    @common_flags ++ sanitizer
  end

  defp crc_flags do
    @common_flags ++ ["-fPIC", "-I", erlang_include()]
  end
end
