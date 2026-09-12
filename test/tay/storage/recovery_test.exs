defmodule Tay.Storage.RecoveryTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Native, Reader, Recovery, Writer}
  import Tay.Test.RecoveryHelpers

  setup do
    Process.flag(:trap_exit, true)
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "empty existing store replays privately and activates the same helper", %{path: path} do
    store(path)
    before = snapshot(path)
    {:ok, writer} = start(path)
    status = Writer.status(writer)
    assert status.state == :awaiting_activation
    assert status.summary.record_count == 0
    refute Map.has_key?(status, :candidate)
    assert snapshot(path) == before
    assert {:error, :admission_reference_required} = Writer.append(writer, 47, 3, <<1>>)
    assert {:error, :not_activated} = Writer.reduce(writer, [], fn _, _, acc -> acc end)
    assert {:ok, summary, []} = activate(writer)
    assert summary.state == :ready
    assert is_reference(summary.admission_ref)
    assert summary.admission_ref != status.session_ref
    assert Writer.status(writer).os_pid == status.os_pid

    assert {:error, :mutation_not_admitted} =
             Writer.append(writer, status.session_ref, 47, 3, <<1>>)

    assert {:ok, %{sequence: 1}} = Writer.append(writer, summary.admission_ref, 47, 3, <<1>>)

    assert {:error, %{reason: :already_activated}} =
             Writer.activate_recovered(writer, status.session_ref)

    GenServer.stop(writer)
    {:ok, reopened} = start(path)
    assert {:ok, _, [{1, 1}]} = activate(reopened)
    GenServer.stop(reopened)
  end

  test "all files replay with exact absolute half-open positions", %{path: path} do
    store(path, [segment(1, 1, [frame(1, 10), frame(2, 20)], true), segment(2, 3, [frame(3, 30)])])

    {:ok, native} = open(path)
    assert {:ok, inspection} = Recovery.inspect(native)
    assert inspection.scope == :physical
    assert inspection.next_sequence == 4
    assert inspection.record_count == 3

    assert {:ok, replay, positions} =
             Recovery.replay(native, Tay.Test.RecoveryDecoder, [], fn _, position, acc ->
               {:ok, [position | acc]}
             end)

    assert Enum.reverse(
             Enum.map(positions, &{&1.segment_id, &1.record_offset, &1.next_offset, &1.sequence})
           ) ==
             [{1, 44, 73, 1}, {1, 73, 102, 2}, {2, 44, 73, 3}]

    assert replay.last_accepted == replay.last_reduced
    assert replay.last_reduced.sequence == 3
    assert :ok = Native.shutdown(native)
  end

  test "highest sealed creates only an empty successor after activation", %{path: path} do
    store(path, [segment(1, 1, [frame(1, 7)], true)])
    before = snapshot(path)
    original = File.read!(canonical(path, 1))
    {:ok, writer} = start(path)
    assert snapshot(path) == before
    assert {:ok, summary, [{1, 7}]} = activate(writer)
    assert summary.highest.id == 2
    assert File.stat!(canonical(path, 2)).size == 44
    assert File.read!(canonical(path, 1)) == original
    assert {:ok, %{sequence: 2}} = Writer.append(writer, summary.admission_ref, 47, 3, <<9>>)
    assert {:ok, %{state: :sealed}} = Writer.seal(writer, summary.admission_ref)
    GenServer.stop(writer)
  end

  test "new traversal halts while physical accumulators keep their old meaning", %{path: path} do
    store(path, [segment(1, 1, [frame(1), frame(2), frame(3)])])
    {:ok, native} = open(path)
    {:ok, view} = Reader.preflight(native)
    parent = self()

    assert {:error, %{kind: :visitor_error, offset: 44}} =
             Reader.reduce_while(native, view, nil, fn record, _, _ ->
               send(parent, {:visit, record.sequence})
               {:error, :halt_here}
             end)

    assert_receive {:visit, 1}
    refute_receive {:visit, 2}
    assert {:ok, %{readable: false}} = Native.info(native)

    assert {:ok, {:error, :just_an_accumulator}} =
             Reader.reduce(native, nil, fn record, _, _ ->
               send(parent, {:old, record.sequence})
               {:error, :just_an_accumulator}
             end)

    for sequence <- 1..3, do: assert_receive({:old, ^sequence})
    Native.shutdown(native)
  end

  test "missing provider, malformed specs and missing storage never bootstrap", %{path: path} do
    for bad <- [%{spec() | codec: nil}, %{spec() | reducer: nil}, Map.put(spec(), :unknown, true)] do
      assert {:error, %{kind: :argument}} = start(path, bad)
      refute File.exists?(path)
    end

    assert {:error, %{kind: :ownership_unavailable}} = start(path)
    refute File.exists?(path)
    File.mkdir_p!(path)
    before = snapshot(path)
    assert {:error, %{kind: :ownership_unavailable}} = start(path)
    assert snapshot(path) == before
    File.write!(Path.join(path, ".tay-owner.lock"), "existing lock")
    before = snapshot(path)
    assert {:error, %{kind: :initialization_required}} = start(path)
    assert snapshot(path) == before
  end

  test "physical mutation sessions cannot masquerade as semantic recovery", %{path: path} do
    {:ok, native} = Native.open(path, durability: :write)
    assert {:error, %{reason: :inspection_session_required}} = Recovery.inspect(native)
    Native.shutdown(native)
  end

  test "fixed physical fixture remains inspectable without assigning it semantic meanings", %{
    path: path
  } do
    store(path, [Tay.Test.SegmentHelpers.fixture("s03.tay")])
    {:ok, native} = open(path)
    assert {:ok, %{record_count: 3}} = Recovery.inspect(native)

    assert {:error, %{kind: :unsupported_semantics}} =
             Recovery.replay(native, Tay.Test.RecoveryDecoder, [], &collect/3)

    Native.shutdown(native)
  end

  test "hot provider replacement invalidates activation authority", %{path: path} do
    module = Tay.Test.RecoveryReloadDecoder
    {^module, original, file} = :code.get_object_code(module)
    store(path, [segment(1, 1, [frame(1)])])
    before = snapshot(path)
    {:ok, writer} = start(path, %{spec() | codec: module})

    try do
      warning = ExUnit.CaptureIO.capture_io(:stderr, fn -> module.replace_for_test() end)
      assert warning =~ "redefining module"

      assert {:error, %{kind: :callback, reason: :event_provider_changed, mutation: :none}} =
               activate(writer)

      assert snapshot(path) == before
    after
      GenServer.stop(writer)
      :code.purge(module)
      :code.load_binary(module, file, original)
    end
  end

  test "an admission reference copied from another live owner is rejected", %{path: path} do
    store(path)
    # Use a sibling disposable root, not an unexpected directory inside a store.
    other = path <> "-other"
    on_exit(fn -> File.rm_rf!(other) end)
    store(other)
    {:ok, first} = start(path)
    {:ok, first_summary, _} = activate(first)
    {:ok, second} = start(other)
    {:ok, _, _} = activate(second)

    assert {:error, :mutation_not_admitted} =
             Writer.append(second, first_summary.admission_ref, 47, 3, <<1>>)

    GenServer.stop(first)
    GenServer.stop(second)
  end

  test "arithmetic exhaustion model exposes no wrapped next sequence or successor budget" do
    # This models only the result/admission arithmetic of an already validated
    # enormous history. It is deliberately NOT a physically valid tiny fixture.
    maximum = Tay.Storage.Segment.max_id()

    store = %{
      store_id: Tay.Test.SegmentHelpers.store_id(),
      segments: [%{count: maximum, bytes: 1_073_741_824}],
      highest: %{id: maximum, state: :sealed},
      next_sequence: maximum + 1,
      exhausted: true
    }

    view = %{store: store, segment_entries: [], staging_count: 0, ignored_count: 0}
    summary = Recovery.summary(view)
    assert summary.next_sequence == :exhausted
    assert summary.physical_last_sequence == maximum
    assert summary.arithmetic_next_sequence == maximum + 1
    {:ok, opts} = Recovery.options(max_total_segment_bytes: 1_073_741_824)
    assert :ok = Recovery.activation_budget(view, opts)
    id_exhausted = %{view | store: %{store | next_sequence: 5}}
    assert Recovery.summary(id_exhausted).next_sequence == :exhausted
    assert Recovery.summary(id_exhausted).arithmetic_next_sequence == 5
  end
end
