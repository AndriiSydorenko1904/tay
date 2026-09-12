defmodule Tay.Storage.SealTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Writer, Segment, Native}
  import Tay.Test.NativeHelpers

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

  test "seal validates the footer and closes the old writable FD", %{path: path} do
    test = self()

    hook = fn
      :r2, n ->
        send(test, {:r2, Native.info(n)})
        :ok

      _, _ ->
        :ok
    end

    {:ok, w} = start(path, on_transition: hook)
    {:ok, _} = Writer.append(w, 1, 1, "seal me")
    file = Path.join([path, "segments", canonical(1)])
    before = File.read!(file)
    assert {:ok, %{state: :sealed, count: 1}} = Writer.seal(w)
    assert_receive {:r2, {:ok, %{writable: 0}}}
    assert binary_part(File.read!(file), 0, byte_size(before)) == before
    assert {:ok, %{state: :sealed}} = Segment.parse(File.read!(file))
    assert {:error, :already_sealed} = Writer.seal(w)
    GenServer.stop(w)
  end

  test "empty sealing is rejected without a footer", %{path: path} do
    {:ok, w} = start(path)
    assert {:error, :empty_segment} = Writer.seal(w)
    assert File.stat!(Path.join([path, "segments", canonical(1)])).size == 44
    GenServer.stop(w)
  end

  test "torn footer remains evidence and cannot be relabeled active", %{path: path} do
    {:ok, w} = start(path)
    {:ok, _} = Writer.append(w, 1, 1, "keep me")
    :ok = Writer.inject_fault(w, :write, 1, :short, 28, 17)
    assert {:error, {:uncertain, %{bytes_written: 17}}} = Writer.seal(w)
    file = Path.join([path, "segments", canonical(1)])
    before = File.read!(file)
    GenServer.stop(w)
    assert {:error, %{kind: :incomplete_footer}} = start(path)
    assert File.read!(file) == before
  end
end
