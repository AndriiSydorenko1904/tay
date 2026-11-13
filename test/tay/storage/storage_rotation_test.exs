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

  test "rotation does not rescan retained segment contents", %{path: path} do
    {:ok, w} = start(path)
    assert {:ok, %{sequence: 1}} = Writer.append(w, 1, 1, "retained")

    # A foreground replay would consume this injected READ_AT fault. Rotation
    # must use only bounded identity/size checks and the maintained CRC state.
    :ok = Writer.inject_fault(w, :read, 1, :error, 5)
    assert {:ok, %{id: 2, count: 0}} = Writer.rotate(w)
    assert {:ok, %{sequence: 2, segment_id: 2}} = Writer.append(w, 1, 1, "next")

    # Prove the fault was still pending, rather than silently ignored.
    assert {:error, _} = Writer.reduce(w, [], fn record, _, acc -> [record.sequence | acc] end)
    GenServer.stop(w)

    assert {:ok, reopened} = start(path)

    assert {:ok, [2, 1]} =
             Writer.reduce(reopened, [], fn record, _, acc -> [record.sequence | acc] end)

    GenServer.stop(reopened)
  end

  test "highest sealed creates only its proved header successor on startup", %{path: path} do
    {:ok, w} = start(path)
    {:ok, _} = Writer.append(w, 1, 1, "sealed")
    {:ok, _} = Writer.seal(w)
    segments = Tay.Test.RecoveryHelpers.segment_directory(path)
    old = File.read!(Path.join(segments, canonical(1)))
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert %{segment: %{id: 2, first_sequence: 2, count: 0}} = Writer.status(w)
    assert File.stat!(Path.join(segments, canonical(2))).size == 44
    assert File.read!(Path.join(segments, canonical(1))) == old
    GenServer.stop(w)
  end

  @tag timeout: 180_000
  test "maximum-size records rotate at the internal segment boundary", %{path: path} do
    {:ok, w} = start(path)
    payload = :binary.copy(<<7>>, 16_777_216)
    count = div(Segment.rotation_bytes() - 108, byte_size(payload) + 28)

    for sequence <- 1..count do
      assert {:ok, %{segment_id: 1, sequence: ^sequence}} = Writer.append(w, 1, 1, payload)
    end

    sequence = count + 1
    assert {:ok, %{segment_id: 2, sequence: ^sequence}} = Writer.append(w, 1, 1, payload)

    assert File.stat!(Path.join(Tay.Test.RecoveryHelpers.segment_directory(path), canonical(1))).size ==
             108 + count * (byte_size(payload) + 28)

    GenServer.stop(w)
  end

  @tag timeout: 180_000
  test "reopen preserves records and automatic rotation policy", %{path: path} do
    {:ok, w} = start(path)
    payload = :binary.copy(<<9>>, 16_777_216)
    count = div(Segment.rotation_bytes() - 108, byte_size(payload) + 28)
    for _ <- 1..count, do: assert({:ok, _} = Writer.append(w, 1, 1, payload))
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert Writer.status(w).segment.count == count
    sequence = count + 1
    assert {:ok, %{sequence: ^sequence, segment_id: 2}} = Writer.append(w, 1, 1, payload)
    GenServer.stop(w)
  end
end
