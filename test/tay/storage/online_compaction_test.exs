defmodule Tay.Storage.OnlineCompactionTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.Writer.OnlineCompaction

  test "delta overload cancels compaction and releases retained records" do
    cancel_flag = :atomics.new(1, [])

    online =
      OnlineCompaction.new(
        ref: make_ref(),
        pid: self(),
        monitor: make_ref(),
        deadline: System.monotonic_time(:millisecond) + 1_000,
        cancel_flag: cancel_flag,
        notify: self(),
        token: make_ref(),
        source: %{},
        max_delta_events: 1,
        max_delta_bytes: 1_000
      )

    online = OnlineCompaction.journal(online, {8, 1, <<1>>})
    assert online.delta_events == 1
    assert :atomics.get(cancel_flag, 1) == 0

    online = OnlineCompaction.journal(online, {8, 1, <<2>>})
    assert online.abort_reason == :checkpoint_delta_overloaded
    assert online.peak_delta_events == 2
    assert online.delta == []
    assert online.delta_events == 0
    assert online.delta_bytes == 0
    assert :atomics.get(cancel_flag, 1) == 1

    assert OnlineCompaction.journal(online, {8, 1, <<3>>}) == online
  end

  test "delta byte limit is independent from the final fence target" do
    cancel_flag = :atomics.new(1, [])

    online =
      OnlineCompaction.new(
        ref: make_ref(),
        pid: self(),
        monitor: make_ref(),
        deadline: System.monotonic_time(:millisecond) + 1_000,
        cancel_flag: cancel_flag,
        notify: self(),
        token: make_ref(),
        source: %{},
        max_delta_events: 100,
        max_delta_bytes: 30
      )
      |> OnlineCompaction.journal({8, 1, <<1, 2, 3>>})

    assert online.abort_reason == :checkpoint_delta_overloaded
    assert online.peak_delta_bytes == 31
    assert online.delta == []
  end
end
