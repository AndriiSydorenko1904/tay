defmodule Tay.Test.NativeHelpers do
  @moduledoc false
  alias Tay.Storage.Native

  def path do
    base = System.get_env("TAY_TEST_DATA_ROOT") || Path.expand("tmp/storage-integration")
    File.mkdir_p!(base)
    Path.join(base, Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
  end

  def native(path, options \\ []) do
    Process.flag(:trap_exit, true)
    Native.open(path, Keyword.merge([durability: :write, test_helper: true], options))
  end

  def stage(id \\ 1),
    do:
      ".tay-new-" <>
        String.pad_leading(Integer.to_string(id), 20, "0") <>
        "-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".tmp"

  def canonical(id), do: elem(Tay.Storage.Segment.filename(id), 1)

  def child_elixir(script, args \\ []) do
    build_lib = :tay |> Application.app_dir() |> Path.dirname() |> Path.expand()

    ebins =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(fn path ->
        expanded = Path.expand(path)

        Path.basename(expanded) == "ebin" and
          Path.dirname(Path.dirname(expanded)) == build_lib
      end)
      |> Enum.sort()

    System.cmd(
      System.find_executable("elixir"),
      Enum.flat_map(ebins, &["-pa", &1]) ++ ["-e", script, "--" | args],
      stderr_to_stdout: true
    )
  end
end
