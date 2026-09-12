defmodule Tay.Storage.RecoveryAdversarialTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Native, Reader, Writer}
  alias Tay.Test.{RecordHelpers, SegmentHelpers}
  import Tay.Test.RecoveryHelpers

  setup do
    Process.flag(:trap_exit, true)
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp refuses(path) do
    before = snapshot(path)
    assert {:error, error} = start(path)
    assert error.action == :preserve_and_stop
    assert error.mutation == :none
    assert snapshot(path) == before
    error
  end

  test "every nonempty partial Record prefix preserves all evidence", %{path: path} do
    store(path)
    record = frame(2, 5)

    for size <- 1..(byte_size(record) - 1) do
      File.write!(canonical(path, 1), segment(1, 1, [frame(1), binary_part(record, 0, size)]))
      error = refuses(path)
      assert error.kind == :incomplete_tail
      assert error.offset == 73
      assert error.physical_reason.available_bytes == size
    end
  end

  test "every partial footer and canonical header refuses activation", %{path: path} do
    record = frame(1)
    header = SegmentHelpers.header()
    footer = SegmentHelpers.footer(header, [record])
    store(path)

    for size <- 1..63 do
      File.write!(canonical(path, 1), header <> record <> binary_part(footer, 0, size))
      assert refuses(path).kind == :incomplete_tail
    end

    for size <- 0..43 do
      File.write!(canonical(path, 1), binary_part(header, 0, size))
      assert refuses(path).kind in [:discovery, :incomplete_tail]
    end
  end

  test "every corrupt frame byte and damaged B before C is preserved", %{path: path} do
    store(path)
    record = frame(2, 6)

    for offset <- 0..(byte_size(record) - 1) do
      damaged = RecordHelpers.flip(record, offset, 0)
      File.write!(canonical(path, 1), segment(1, 1, [frame(1), damaged, frame(3)]))
      assert refuses(path).kind in [:physical_corruption, :unsupported_physical]
    end
  end

  test "corrupted length with recomputed CRC cannot discard hidden valid C", %{path: path} do
    hidden = frame(3, 99)
    damaged = frame(2, 7, payload: <<7>> <> hidden, payload_length: 1024)
    store(path, [segment(1, 1, [frame(1), damaged])])
    error = refuses(path)
    assert error.kind == :incomplete_tail

    assert error.physical_reason.reason ==
             RecordHelpers.incomplete(
               RecordHelpers.record(
                 sequence: 2,
                 record_type: 47,
                 payload_schema_version: 3,
                 payload: :binary.copy(<<0>>, 1024)
               ),
               byte_size(damaged)
             )

    assert :binary.match(File.read!(canonical(path, 1)), hidden) != :nomatch
  end

  test "earlier incomplete history, wrong anchors and trailing footer data never become a prefix",
       %{path: path} do
    first = segment(1, 1, [frame(1)], true)
    store(path, [first, segment(2, 2, [frame(2)])])

    for damaged <- [
          segment(1, 1, [frame(1)]),
          first <> <<0>>,
          first <> binary_part(first, byte_size(first) - 64, 64)
        ] do
      File.write!(canonical(path, 1), damaged)
      refuses(path)
    end

    File.write!(canonical(path, 1), first)
    File.write!(canonical(path, 2), segment(2, 3, [frame(3)]))
    refuses(path)
    File.write!(canonical(path, 2), segment(2, 2, [frame(2), frame(2)]))
    assert refuses(path).kind == :continuity
  end

  test "STORE version stays unsupported rather than repairable corruption", %{path: path} do
    store(path)

    File.write!(
      Path.join(path, "STORE"),
      SegmentHelpers.checked(<<"TAYI", 2, 0, 0::16, SegmentHelpers.store_id()::binary>>)
    )

    assert refuses(path).kind == :unsupported_physical
  end

  test "stages are retained and never promoted; unsupported semantics still cannot sync", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1, 1, record_type: 49)], true)])
    stage = Path.join([path, "segments", Tay.Test.NativeHelpers.stage(2)])
    File.write!(stage, SegmentHelpers.header(id: 2, first_sequence: 2))
    parent = self()

    hook = fn :recovery_acquired, native ->
      {:ok, info} = Native.info(native)
      send(parent, {:info, info})
      # If any sync opcode runs during replay it would fail; it must not run.
      Native.fault(native, :sync_read, 1, :error)
    end

    before = snapshot(path)
    assert {:error, %{kind: :unsupported_semantics}} = start(path, spec(), on_transition: hook)
    assert_receive {:info, %{ancestor_syncs: 0, writable: 0, readable: false}}
    assert snapshot(path) == before
    File.write!(stage, :binary.copy(<<0>>, 45))
    assert refuses(path).kind == :discovery
  end

  test "changed bytes with same inode/extent invalidate a retained candidate", %{path: path} do
    store(path, [segment(1, 1, [frame(1, 1)])])
    {:ok, writer} = start(path)
    original_inode = File.stat!(canonical(path, 1)).inode
    File.write!(canonical(path, 1), segment(1, 1, [frame(1, 2)]))
    assert File.stat!(canonical(path, 1)).inode == original_inode
    changed = snapshot(path)
    assert {:error, %{kind: :changed_view, mutation: :none}} = activate(writer)
    assert snapshot(path) == changed
    refute Map.has_key?(Writer.status(writer), :candidate)
    GenServer.stop(writer)
  end

  test "sequence against frozen view is checked before semantic traversal", %{path: path} do
    store(path, [segment(1, 1, [frame(1)])])
    {:ok, native} = open(path)
    {:ok, view} = Reader.preflight(native)
    File.write!(canonical(path, 1), segment(1, 2, [frame(2)]))
    parent = self()

    assert {:error, _} =
             Reader.reduce_while(native, view, [], fn _, _, acc ->
               send(parent, :visited)
               {:cont, acc}
             end)

    refute_receive :visited
    Native.shutdown(native)
  end

  test "operational budgets refuse unchanged valid bytes and permit larger-budget retries", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1), frame(2)])])
    before = snapshot(path)

    for options <- [
          [max_decode_payload_bytes: 0],
          [max_replay_records: 0],
          [max_replay_records: 1],
          [max_total_segment_bytes: 50],
          [max_directory_entries: 2],
          [event_limits: %{depth: 1, output_nodes: 2, binary_bytes: 1}],
          [event_limits: %{depth: 2, output_nodes: 1, binary_bytes: 1}],
          [event_limits: %{depth: 2, output_nodes: 2, binary_bytes: 0}]
        ] do
      assert {:error, %{kind: :resource_limit, mutation: :none}} = start(path, spec(options))
      assert snapshot(path) == before
    end

    {:ok, writer} = start(path)
    assert {:ok, _, [{2, 1}, {1, 1}]} = activate(writer)
    GenServer.stop(writer)
  end

  test "successor budget is admitted before promotion or transient publication", %{path: path} do
    store(path, [segment(1, 1, [frame(1)], true)])
    File.write!(Path.join([path, "segments", "unrelated-a"]), <<>>)
    File.write!(Path.join([path, "segments", "unrelated-b"]), <<>>)

    for opts <- [[max_total_segment_bytes: 137], [max_directory_entries: 3]] do
      before = snapshot(path)
      {:ok, writer} = start(path, spec(opts))
      assert {:error, %{kind: :resource_limit, mutation: :none}} = activate(writer)
      assert snapshot(path) == before
      GenServer.stop(writer)
    end

    {:ok, writer} = start(path)
    assert {:ok, _, [{1, 1}]} = activate(writer)
    assert File.stat!(canonical(path, 2)).size == 44
    GenServer.stop(writer)
  end

  test "unknown, duplicate or invalid operational options fail before storage acquisition", %{
    path: path
  } do
    for options <- [
          [max_replay_records: 1, max_replay_records: 2],
          [repair: true],
          [max_decode_payload_bytes: 16_777_217],
          [max_directory_entries: 0],
          [deadline_ms: 0],
          [activation_window_ms: -1],
          [activation_deadline_ms: nil],
          [io_timeout_ms: 0],
          [event_limits: %{depth: 1}],
          [max_total_segment_bytes: 0],
          [max_replay_records: -1]
        ] do
      assert {:error, %{kind: :argument}} = start(path, spec(options))
      refute File.exists?(path)
    end
  end

  @tag timeout: 180_000
  test "exact 16 MiB payload is valid and lowering decode budget does not change its validity", %{
    path: path
  } do
    bytes = :binary.copy(<<131>>, 16_777_216)
    store(path, [segment(1, 1, [frame(1, 0, payload: bytes)])])
    before = snapshot(path)

    replay = %{
      spec()
      | codec: Tay.Test.RecoverySizeDecoder,
        initial_acc: 0,
        reducer: fn {:size, size}, _, total -> {:ok, total + size} end
    }

    assert {:error, %{kind: :resource_limit}} =
             start(
               path,
               %{replay | options: [max_decode_payload_bytes: 16_777_215]}
             )

    assert snapshot(path) == before
    {:ok, writer} = start(path, replay, rotation_target_bytes: 16_777_352)
    assert {:ok, _, 16_777_216} = activate(writer)
    GenServer.stop(writer)
  end

  test "an incomplete unknown-semantic record is never discarded as unsupported", %{path: path} do
    unknown = frame(2, 3, record_type: 49, payload_schema_version: 255)
    store(path, [segment(1, 1, [frame(1), binary_part(unknown, 0, 26)])])
    assert refuses(path).kind == :incomplete_tail
  end

  test "symlink and hard-link ownership objects are never replaced", %{path: path} do
    store(path)
    lock = Path.join(path, ".tay-owner.lock")
    retained = Path.join(path, "retained-test-lock")
    File.rename!(lock, retained)
    File.ln_s!(retained, lock)
    refuses(path)
    File.rm!(lock)
    File.ln!(retained, lock)
    refuses(path)
  end

  test "a FIRST-max record is not accepted as a fresh genesis or rebased history", %{path: path} do
    maximum = Tay.Storage.Segment.max_id()
    store(path, [segment(1, maximum, [frame(maximum)])])
    assert refuses(path).kind == :continuity
  end
end
