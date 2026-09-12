defmodule Tay.Storage.AppendTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Writer, Native}
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

  test "append and reopen preserve records and the next physical sequence", %{path: path} do
    {:ok, w} = start(path)

    for n <- 1..20 do
      assert {:ok, %{sequence: ^n, durability: :write}} = Writer.append(w, 47, 3, <<n, 0, 255>>)
    end

    assert {:ok, records} = Writer.reduce(w, [], fn r, _, acc -> [r | acc] end)
    assert Enum.map(Enum.reverse(records), & &1.sequence) == Enum.to_list(1..20)
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert Writer.status(w).next_sequence == 21
    assert {:ok, %{sequence: 21}} = Writer.append(w, 1, 1, "after reopen")
    GenServer.stop(w)
  end

  test "invalid insertion fields do not consume sequence or poison the writer", %{path: path} do
    {:ok, w} = start(path)
    assert {:error, _} = Writer.append(w, 0, 1, "invalid type")
    assert {:error, _} = Writer.append(w, 1, 0, "invalid schema")
    assert {:error, _} = Writer.append(w, 1, 1, %{not: :bytes})
    assert Writer.status(w).next_sequence == 1
    assert {:ok, %{sequence: 1}} = Writer.append(w, 1, 1, "ok")
    GenServer.stop(w)
  end

  test "short append leaves exact evidence and a permanently poisoned writer", %{path: path} do
    {:ok, w} = start(path)
    {:ok, _} = Writer.append(w, 1, 1, "acknowledged")
    file = Path.join([path, "segments", canonical(1)])
    before = File.read!(file)
    :ok = Writer.inject_fault(w, :write, 1, :short, 28, 12)
    assert {:error, {:uncertain, %{bytes_written: 12}}} = Writer.append(w, 1, 1, "torn")
    assert %{state: :poisoned, next_sequence: 2} = Writer.status(w)
    assert {:error, {:poisoned, _}} = Writer.append(w, 1, 1, "never appended")
    after_bytes = File.read!(file)
    assert binary_part(after_bytes, 0, byte_size(before)) == before
    assert byte_size(after_bytes) == byte_size(before) + 12
    GenServer.stop(w)
    assert {:error, %{kind: :incomplete_record}} = start(path)
    assert File.read!(file) == after_bytes
  end

  test "completed append with lost response occupies its sequence on reopen", %{path: path} do
    hook = fn
      :append_written, n ->
        :ok = Native.fault(n, :check, 1, :crash_before)
        :ok

      _, _ ->
        :ok
    end

    {:ok, w} = start(path, on_transition: hook)
    assert {:error, {:uncertain, _}} = Writer.append(w, 1, 1, "possibly committed")
    GenServer.stop(w)
    {:ok, reopened} = start(path)
    assert Writer.status(reopened).next_sequence == 2
    assert {:ok, %{sequence: 2}} = Writer.append(reopened, 1, 1, "distinct later record")
    GenServer.stop(reopened)
  end
end
