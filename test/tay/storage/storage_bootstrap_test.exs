defmodule Tay.Storage.BootstrapTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Writer, Segment}
  import Tay.Test.NativeHelpers
  import Tay.Test.SegmentHelpers, only: [fixture: 1]

  setup do
    Process.flag(:trap_exit, true)
    path = path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, opts \\ []),
    do:
      Writer.start_link(
        Keyword.merge([data_dir: path, durability: :write, test_helper: true], opts)
      )

  test "new directory bootstrap produces the approved bytes and reopens", %{path: path} do
    assert {:ok, writer} = start(path)

    assert %{state: :ready, segment: %{state: :active, count: 0}, next_sequence: 1} =
             Writer.status(writer)

    assert {:ok, store_id} = Segment.decode_store(File.read!(Path.join(path, "STORE")))

    assert {:ok, %{id: 1, first_sequence: 1, store_id: ^store_id}} =
             Segment.parse(File.read!(Path.join([path, "segments", canonical(1)])))

    GenServer.stop(writer)
    assert {:ok, next} = start(path)
    assert Writer.status(next).segment.store_id == store_id
    GenServer.stop(next)
  end

  test "existing empty directory requires explicit bootstrap intent", %{path: path} do
    File.mkdir!(path)
    assert {:error, :explicit_bootstrap_required} = start(path)
    refute File.exists?(Path.join(path, "STORE"))
    assert {:ok, writer} = start(path, bootstrap: true)
    GenServer.stop(writer)
  end

  test "the proved bare ID1 header finishes the same marker", %{path: path} do
    File.mkdir_p!(Path.join(path, "segments"))
    File.write!(Path.join([path, "segments", canonical(1)]), fixture("s01.tay"))
    assert {:ok, writer} = start(path)
    assert File.read!(Path.join(path, "STORE")) == fixture("STORE")
    GenServer.stop(writer)
  end

  test "missing marker with records and initialized missing history fail", %{path: path} do
    File.mkdir_p!(Path.join(path, "segments"))
    file = Path.join([path, "segments", canonical(1)])
    File.write!(file, fixture("s02.tay"))
    assert {:error, %{reason: :missing_store_marker}} = start(path, bootstrap: true)
    assert File.read!(file) == fixture("s02.tay")
    refute File.exists?(Path.join(path, "STORE"))
  end

  test "invalid options and absent production data_dir fail before I/O", %{path: path} do
    assert {:error, :data_dir_required} = Writer.start_link(durability: :write)
    assert {:error, :invalid_durability} = start(path, durability: :flush)
    assert {:error, :invalid_rotation_target} = start(path, rotation_target_bytes: 100)
    refute File.exists?(path)
    {:ok, config} = Tay.Config.new([])
    assert {:error, {:invalid_config, :data_dir, _}} = Tay.Config.validate_startup(config, :prod)
  end
end
