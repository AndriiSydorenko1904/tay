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
    ebins =
      [
        :tay,
        :telemetry,
        :grpc_server,
        :grpc_core,
        :googleapis,
        :protobuf,
        :cowboy,
        :cowlib,
        :ranch,
        :flow,
        :gen_stage,
        :jason
      ]
      |> Enum.map(&Application.app_dir(&1, "ebin"))

    System.cmd(
      System.find_executable("elixir"),
      Enum.flat_map(ebins, &["-pa", &1]) ++ ["-e", script, "--" | args],
      stderr_to_stdout: true
    )
  end
end
