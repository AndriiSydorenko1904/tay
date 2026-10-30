defmodule Mix.Tasks.Compile.TayNative do
  use Mix.Task.Compiler
  import Bitwise

  @source Path.expand("../c_src/tay_storage_helper.c", __DIR__)
  @crc_source Path.expand("../c_src/tay_crc32c.c", __DIR__)
  @crc_fuzz_source Path.expand("../c_src/tay_crc32c_fuzz.c", __DIR__)
  @common_flags ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Wformat=2"]

  @impl true
  def run(args) do
    if Mix.Project.config()[:app] == :tay,
      do: compile_native("--force" in args),
      else: {:noop, []}
  end

  @impl true
  def manifests, do: [Path.join(Mix.Project.manifest_path(), "compile.tay_native")]

  @impl true
  def clean do
    for name <- ["tay_storage_helper", "tay_storage_helper_test", "tay_crc32c.so"],
        do: File.rm(Path.join([Mix.Project.app_path(), "priv", name]))

    Enum.each(manifests(), &File.rm/1)
    :ok
  end

  defp compile_native(force) do
    cc = compiler!()
    dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(dir)

    # Even a cached production build must remove the fault-enabled executable.
    if Mix.env() != :test do
      case File.rm(Path.join(dir, "tay_storage_helper_test")) do
        result when result in [:ok, {:error, :enoent}] -> :ok
        _ -> Mix.raise("Cannot remove stale generated test helper from build output")
      end
    end

    {version, 0} = System.cmd(cc, ["--version"], stderr_to_stdout: true)

    headers =
      for path <- Path.wildcard(Path.join(erlang_include(), "*.h")), do: {path, File.read!(path)}

    identity = {cc, version, :os.type(), :erlang.system_info(:system_architecture), Mix.env()}
    previous = read_manifest()

    entries =
      for {name, source, flags, executable?} <- builds() do
        artifact = Path.join(dir, name)

        inputs =
          {identity, source, File.read!(source), flags, if(executable?, do: [], else: headers)}

        fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(inputs))
        valid? = valid_artifact?(artifact, executable?)
        changed? = force or not valid? or Map.get(previous, name) != fingerprint
        if changed?, do: build!(cc, flags, source, artifact, executable?)
        {name, fingerprint, changed?}
      end

    manifest = Map.new(entries, fn {name, fingerprint, _} -> {name, fingerprint} end)
    changed? = Enum.any?(entries, &elem(&1, 2)) or manifest != previous

    if changed? do
      [path] = manifests()
      File.mkdir_p!(Path.dirname(path))
      atomic_write!(path, :erlang.term_to_binary(manifest))
    end

    {if(changed?, do: :ok, else: :noop), []}
  end

  defp builds do
    helper = [{"tay_storage_helper", @source, helper_flags(), true}]

    helper =
      if Mix.env() == :test,
        do:
          helper ++
            [{"tay_storage_helper_test", @source, helper_flags() ++ ["-DTAY_TEST_FAULTS"], true}],
        else: helper

    helper ++ [{"tay_crc32c.so", @crc_source, crc_flags() ++ linker_flags(), false}]
  end

  defp read_manifest do
    with [path] <- manifests(),
         {:ok, bytes} <- File.read(path),
         manifest when is_map(manifest) <- :erlang.binary_to_term(bytes, [:safe]) do
      manifest
    else
      _ -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp valid_artifact?(path, executable?) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> not executable? or (mode &&& 0o111) != 0
      _ -> false
    end
  end

  defp build!(cc, flags, source, artifact, executable?) do
    temporary = artifact <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      case System.cmd(cc, flags ++ [source, "-o", temporary], stderr_to_stdout: true) do
        {_, 0} ->
          unless valid_artifact?(temporary, executable?),
            do: Mix.raise("Native compiler produced an invalid artifact")

          File.rename!(temporary, artifact)

        {output, code} ->
          Mix.raise("Native compilation failed (#{code}):\n#{output}")
      end
    after
      File.rm(temporary)
    end
  end

  defp atomic_write!(path, bytes) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, bytes)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp linker_flags do
    case :os.type() do
      {:unix, :darwin} -> ["-dynamiclib", "-undefined", "dynamic_lookup"]
      {:unix, :linux} -> ["-shared"]
      platform -> Mix.raise("Unsupported platform for Tay CRC32C NIF: #{inspect(platform)}")
    end
  end

  @doc false
  def compilation_commands do
    cc = compiler!()

    # The fuzz harness belongs to source checkouts and is absent from Hex packages.
    fuzz =
      if File.regular?(@crc_fuzz_source),
        do: [
          {@crc_fuzz_source,
           [
             "-std=c11",
             "-Wall",
             "-Wextra",
             "-Werror",
             "-g",
             "-O1",
             "-DTAY_FUZZ_STANDALONE",
             "-fsanitize=address,undefined",
             "-fno-omit-frame-pointer"
           ]}
        ],
        else: []

    for {source, flags} <- [{@source, helper_flags()}, {@crc_source, crc_flags()}] ++ fuzz,
        do: %{directory: File.cwd!(), file: source, arguments: [cc | flags] ++ ["-c", source]}
  end

  @doc false
  def erlang_include, do: Path.join([List.to_string(:code.root_dir()), "usr", "include"])

  defp compiler!,
    do:
      System.find_executable("cc") || Mix.raise("A C compiler is required for Tay's native code")

  defp helper_flags do
    sanitizer =
      if System.get_env("TAY_NATIVE_SANITIZE") == "1",
        do: ["-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-g"],
        else: []

    @common_flags ++ sanitizer
  end

  defp crc_flags, do: @common_flags ++ ["-fPIC", "-I", erlang_include()]
end
