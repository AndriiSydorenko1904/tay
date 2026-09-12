defmodule Tay.State.RecoveryTest do
  use ExUnit.Case, async: true
  alias Tay.Event
  alias Tay.State.Transition, as: T
  alias Tay.Storage.{Record, Writer}
  alias Tay.Test.{EventHelpers, NativeHelpers, RecoveryHelpers}
  alias Tay.Test.RecoveryHelpers, as: R

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp spec(initial \\ T.candidate(), options \\ []),
    do: %{codec: Event, initial_acc: initial, reducer: &T.reduce/3, options: options}

  test "production decoder reconstructs full history without registry/time/ETS or ACK knowledge",
       %{path: path} do
    frames = Enum.map(~w(E1 E2 E3 E4 E6 E5), &EventHelpers.fixture/1)

    R.store(path, [
      R.segment(1, 1, Enum.take(frames, 3), true),
      R.segment(2, 4, Enum.drop(frames, 3))
    ])

    before = R.snapshot(path)
    {:ok, writer} = R.start(path, spec())
    physical = Writer.status(writer)
    assert physical.state == :awaiting_activation
    assert R.snapshot(path) == before
    assert {:ok, summary, candidate} = R.activate(writer)
    assert summary.record_count == 6
    assert candidate.jobs[EventHelpers.id()].state == :cancelled
    assert candidate.jobs[EventHelpers.id()].revision == 6
    assert Writer.status(writer).os_pid == physical.os_pid
    GenServer.stop(writer)
  end

  test "unknown types/schemas/transition errors and tails preserve all evidence", %{path: path} do
    for {suffix, type, schema, payload, expected} <- [
          {"type", 47, 1, <<>>, :unsupported_semantics},
          {"schema", 1, 2, <<>>, :unsupported_semantics},
          {"payload", 1, 1, <<131, 80>>, :invalid_payload},
          {"transition", 3, 1, binary_part(EventHelpers.fixture("N7"), 24, 130),
           :consumer_rejected}
        ] do
      dir = path <> suffix
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, frame} =
        Record.encode(%Record{
          record_type: type,
          payload_schema_version: schema,
          sequence: 1,
          payload: payload
        })

      R.store(dir, [R.segment(1, 1, [frame], true)])
      before = R.snapshot(dir)
      assert {:error, %{kind: ^expected}} = R.start(dir, spec())
      assert R.snapshot(dir) == before
    end

    frame = EventHelpers.fixture("E1")
    R.store(path, [R.segment(1, 1, [binary_part(frame, 0, byte_size(frame) - 1)])])
    before = R.snapshot(path)
    assert {:error, _} = R.start(path, spec())
    assert R.snapshot(path) == before
  end

  test "candidate and decoder budget failures retry on unchanged storage", %{path: path} do
    R.store(path, [R.segment(1, 1, [EventHelpers.fixture("E1")], true)])
    before = R.snapshot(path)

    for replay_spec <- [
          spec(T.candidate(%{max_jobs: 0})),
          spec(T.candidate(),
            event_limits: %{depth: 3, output_nodes: 100_000, binary_bytes: 16_777_216}
          )
        ] do
      assert {:error, %{kind: :resource_limit}} =
               RecoveryHelpers.after_release(fn -> R.start(path, replay_spec) end)

      assert R.snapshot(path) == before
    end

    {:ok, writer} = R.after_release(fn -> R.start(path, spec()) end)
    assert {:ok, _, candidate} = R.activate(writer)
    assert map_size(candidate.jobs) == 1
    GenServer.stop(writer)
  end
end
