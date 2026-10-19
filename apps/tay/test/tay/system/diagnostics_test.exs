defmodule Tay.DiagnosticsTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Tay.Test.NativeHelpers
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Storage.Native

  setup do
    path = NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp inspect_store(path, extra \\ []),
    do:
      R.after_release(fn ->
        Tay.Diagnostics.inspect([data_dir: path, durability: :write] ++ extra)
      end)

  test "full semantic inspection returns bounded aggregates without activation or jobs", %{
    path: path
  } do
    R.store(path)
    before = R.snapshot(path)
    assert {:ok, result} = inspect_store(path)
    assert result.record_count == 0 and result.segment_count == 1
    assert result.jobs == 0
    assert result.activation == :not_attempted and result.mutation == :none
    refute Map.has_key?(result, :candidate)
    refute Map.has_key?(result, :segments)
    refute Map.has_key?(result, :admission_ref)
    assert byte_size(Tay.Diagnostics.format({:ok, result})) < 2048
    assert R.snapshot(path) == before
    refute File.exists?(R.canonical(path, 2))
  end

  test "missing root or lock never bootstraps and a held owner is refused", %{path: path} do
    assert {:error, %{stage: :ownership}} = inspect_store(path)
    refute File.exists?(path)
    R.store(path)
    File.rm!(Path.join(path, ".tay-owner.lock"))
    before = R.snapshot(path)
    assert {:error, %{stage: :ownership}} = inspect_store(path)
    assert R.snapshot(path) == before
    File.write!(Path.join(path, ".tay-owner.lock"), "")
    {:ok, native} = R.open(path)

    assert {:error, %{kind: :ownership_busy}} =
             Tay.Diagnostics.inspect(data_dir: path, durability: :write)

    Native.shutdown(native)
  end

  test "large accepted recovery deadlines do not overflow the isolation receive timer", %{
    path: path
  } do
    options = [recovery: [deadline_ms: 4_294_967_296_000]]
    assert {:error, %{stage: :ownership}} = inspect_store(path, options)
    refute File.exists?(path)
    R.store(path)
    before = R.snapshot(path)
    assert {:ok, %{jobs: 0, mutation: :none}} = inspect_store(path, options)
    assert R.snapshot(path) == before
  end

  test "Mix task argument contract excludes force, repair, mutation and implicit paths" do
    for operation <- [:init, :inspect],
        flags <- [
          [],
          ["--force"],
          ["--repair"],
          ["--offset", "0"],
          ["--data-dir", "/somewhere", "--durability", "fast"]
        ] do
      assert {:error, _} = Tay.Diagnostics.cli_options(flags, operation)
    end

    assert {:ok, init} =
             Tay.Diagnostics.cli_options(
               ["--data-dir", "/store", "--durability", "write", "--bootstrap-existing"],
               :init
             )

    assert init[:bootstrap] == true and init[:durability] == :write

    assert {:error, _} =
             Tay.Diagnostics.cli_options(
               ["--data-dir", "/store", "--bootstrap-existing"],
               :inspect
             )
  end

  test "Mix init and inspect tasks operate offline and refuse reinitialization", %{path: path} do
    original = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original) end)
    args = ["--data-dir", path, "--durability", "write"]
    Mix.Tasks.Tay.Storage.Init.run(args)
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ ":ok"
    R.after_release(fn -> Tay.Diagnostics.inspect(data_dir: path, durability: :write) end)
    Mix.Tasks.Tay.Storage.Inspect.run(args)
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "physical_and_semantic"
    before = R.snapshot(path)
    assert_raise Mix.Error, fn -> Mix.Tasks.Tay.Storage.Init.run(args) end
    assert R.snapshot(path) == before
  end
end
