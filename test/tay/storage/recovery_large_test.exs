defmodule Tay.Storage.RecoveryLargeTest do
  use ExUnit.Case, async: false
  alias Tay.Storage.Native
  alias Tay.Test.{RecordHelpers, SegmentHelpers}
  import Tay.Test.RecoveryHelpers
  @moduletag :large_recovery
  @moduletag timeout: 1_800_000
  if System.get_env("TAY_LARGE_RECOVERY_TEST") != "1" do
    @moduletag skip: "run explicitly with TAY_LARGE_RECOVERY_TEST=1"
  end

  setup do
    Process.flag(:trap_exit, true)
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "exact 1 GiB existing segment replays and activates with bounded reads and constant-size candidate",
       %{path: path} do
    store(path)
    header = SegmentHelpers.header()
    payload = :binary.copy(<<7>>, 16_777_216)
    {:ok, file} = File.open(canonical(path, 1), [:write, :binary])
    IO.binwrite(file, header)
    # Independent record encoder/oracle. Only one frame is generated at a time.
    {crc, offset, payload_bytes} =
      Enum.reduce(
        1..64,
        {Tay.Storage.CRC32C.update(Tay.Storage.CRC32C.initial(), header), 44, 0},
        fn sequence, {crc, offset, total} ->
          n = if sequence == 64, do: 1_073_741_824 - 64 - offset - 28, else: 16_777_216

          bytes =
            RecordHelpers.frame(
              sequence: sequence,
              record_type: 47,
              payload_schema_version: 3,
              payload: binary_part(payload, 0, n)
            )

          :ok = IO.binwrite(file, bytes)
          {Tay.Storage.CRC32C.update(crc, bytes), offset + byte_size(bytes), total + n}
        end
      )

    assert offset == 1_073_741_824 - 64

    footer =
      SegmentHelpers.footer(header, [],
        count: 64,
        last_sequence: 64,
        segment_crc: Tay.Storage.CRC32C.finalize(crc)
      )

    :ok = IO.binwrite(file, footer)
    :ok = File.close(file)
    assert File.stat!(canonical(path, 1)).size == 1_073_741_824

    parent = self()
    :erlang.trace_pattern({Native, :read, 3}, true, [:local])

    hook = fn
      :recovery_acquired, _ ->
        :erlang.trace(self(), true, [:call, {:tracer, parent}])
        :ok

      _, _ ->
        :ok
    end

    replay = %{
      spec(deadline_ms: 1_800_000, activation_deadline_ms: 1_800_000)
      | codec: Tay.Test.RecoverySizeDecoder,
        initial_acc: {0, 0},
        reducer: fn {:size, size}, _, {count, total} -> {:ok, {count + 1, total + size}} end
    }

    try do
      {:ok, writer} = start(path, replay, on_transition: hook)
      assert {:ok, summary, {64, ^payload_bytes}} = activate(writer)
      assert summary.next_sequence == 65
      assert summary.highest.id == 2
      assert File.stat!(canonical(path, 2)).size == 44
      :erlang.trace(writer, false, [:call])
      delivered = :erlang.trace_delivered(writer)
      assert_receive {:trace_delivered, ^writer, ^delivered}, 5_000
      reads = collect_reads(writer, [])
      assert length(reads) > 64 * 3
      assert Enum.max(reads) == 16_777_244
      assert Enum.all?(reads, &(&1 in 0..16_777_244))
      GenServer.stop(writer)
    after
      :erlang.trace_pattern({Native, :read, 3}, false, [:local])
    end
  end

  test "many small segments have bounded inventory and retryable budgets", %{path: path} do
    count = 300
    files = for id <- 1..count, do: segment(id, id, [frame(id, rem(id, 256))], id < count)
    store(path, files)
    before = snapshot(path)
    assert {:error, %{kind: :resource_limit}} = start(path, spec(max_directory_entries: 100))
    assert snapshot(path) == before
    {:ok, writer} = start(path, spec(max_directory_entries: 301))
    assert {:ok, %{record_count: ^count, next_sequence: 301}, candidate} = activate(writer)
    assert length(candidate) == count
    GenServer.stop(writer)
  end

  defp collect_reads(writer, acc) do
    receive do
      {:trace, ^writer, :call, {Native, :read, [_native, _offset, length]}} ->
        collect_reads(writer, [length | acc])
    after
      0 -> acc
    end
  end
end
