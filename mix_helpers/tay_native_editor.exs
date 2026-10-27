defmodule Mix.Tasks.Tay.Native.Editor do
  use Mix.Task

  @shortdoc "Generates C/C++ editor configuration for Tay's native sources"
  @moduledoc """
  Generates the compilation database and Erlang header symlink consumed by
  Tay's VS Code configuration:

      mix tay.native.editor

  Run in the repository root after changing Erlang installations or cleaning
  the build directory. This task does not compile C code or start Tay.
  `mix compile` does not generate or update editor configuration.
  """

  @impl Mix.Task
  def run(args) do
    if args != [], do: Mix.raise("Usage: mix tay.native.editor")

    commands = Mix.Tasks.Compile.TayNative.compilation_commands()
    include = Mix.Tasks.Compile.TayNative.erlang_include()

    unless File.regular?(Path.join(include, "erl_nif.h")),
      do: Mix.raise("Cannot find Erlang NIF headers in #{include}")

    build = Mix.Project.build_path()
    File.mkdir_p!(build)
    link_erlang_headers(include, Path.join(build, "tay_erl_include"))
    database = Path.join(build, "tay_compile_commands.json")
    File.write!(database, JSON.encode!(commands) <> "\n")
    Mix.shell().info("Native editor configuration: #{database}")
  end

  defp link_erlang_headers(include, link) do
    case File.read_link(link) do
      {:ok, ^include} ->
        :ok

      {:ok, _old_include} ->
        File.rm!(link)
        File.ln_s!(include, link)

      {:error, :enoent} ->
        File.ln_s!(include, link)

      {:error, reason} ->
        Mix.raise("Cannot configure Erlang editor headers at #{link}: #{inspect(reason)}")
    end
  end
end
