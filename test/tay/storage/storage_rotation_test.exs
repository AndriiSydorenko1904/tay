defmodule Tay.Storage.RotationTest do
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

  test "multiple rotations preserve sequence and only one writable canonical FD", %{path: path} do
    test = self()

    hook = fn tag, n ->
      if tag in [:r2, :r3, :r4, :r5, :r6, :r7], do: send(test, {tag, Native.info(n)})
      :ok
    end

    {:ok, w} = start(path, on_transition: hook)
    assert {:ok, %{id: 1, count: 0}} = Writer.rotate(w)

    for id <- 1..3 do
      assert {:ok, %{sequence: ^id}} = Writer.append(w, 1, 1, <<id>>)
      assert {:ok, %{id: next, count: 0}} = Writer.rotate(w)
      assert next == id + 1

      for {tag, fd} <- [r2: 0, r3: 2, r4: 0, r5: 0, r6: 0, r7: 1] do
        assert_receive {^tag, {:ok, %{writable: ^fd}}}
      end
    end

    assert {:ok, [3, 2, 1]} = Writer.reduce(w, [], fn r, _, acc -> [r.sequence | acc] end)
    GenServer.stop(w)
    {:ok, reopened} = start(path)
    assert Writer.status(reopened).segment.id == 4
    assert {:ok, %{sequence: 4}} = Writer.append(reopened, 1, 1, "after reopen")
    GenServer.stop(reopened)
  end

  test "highest sealed creates only its proved header successor on startup", %{path: path} do
    {:ok, w} = start(path)
    {:ok, _} = Writer.append(w, 1, 1, "sealed")
    {:ok, _} = Writer.seal(w)
    old = File.read!(Path.join([path, "segments", canonical(1)]))
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert %{segment: %{id: 2, first_sequence: 2, count: 0}} = Writer.status(w)
    assert File.stat!(Path.join([path, "segments", canonical(2)])).size == 44
    assert File.read!(Path.join([path, "segments", canonical(1)])) == old
    GenServer.stop(w)
  end

  @tag timeout: 120_000
  test "the maximum record fits exactly; the next record rotates before append", %{path: path} do
    {:ok, w} = start(path, rotation_target_bytes: Segment.min_rotation_bytes())
    payload = :binary.copy(<<7>>, 16_777_216)
    assert {:ok, %{segment_id: 1, sequence: 1}} = Writer.append(w, 1, 1, payload)
    assert {:ok, %{segment_id: 2, sequence: 2}} = Writer.append(w, 1, 1, <<>>)

    assert File.stat!(Path.join([path, "segments", canonical(1)])).size ==
             Segment.min_rotation_bytes()

    assert Writer.status(w).segment.bytes == 72
    GenServer.stop(w)
  end

  @tag timeout: 120_000
  test "lower insertion threshold after reopen does not invalidate stored bytes", %{path: path} do
    {:ok, w} = start(path)
    payload = :binary.copy(<<9>>, 8_388_608)
    {:ok, _} = Writer.append(w, 1, 1, payload)
    {:ok, _} = Writer.append(w, 1, 1, payload)
    GenServer.stop(w)
    {:ok, w} = start(path, rotation_target_bytes: Segment.min_rotation_bytes())
    assert Writer.status(w).segment.count == 2
    assert {:ok, %{sequence: 3, segment_id: 2}} = Writer.append(w, 1, 1, "rotate")
    GenServer.stop(w)
  end
end
