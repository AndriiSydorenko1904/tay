defmodule Tay.Standalone.RuntimeMonitorTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true
  @name __MODULE__.Engine

  test "failed status shuts down the whole standalone supervision tree" do
    :ets.new(@name, [:named_table, :public, :set])

    metadata = %{
      slots: 1,
      memory: Tay.State.Memory.new(1_024),
      client_memory: Tay.State.Memory.new(1_024),
      client_bytes: 1_024,
      status: %{state: :ready}
    }

    :ets.insert(@name, [{:meta, metadata}, {1, nil, nil, :free, 0}])

    {:ok, supervisor} =
      Supervisor.start_link(
        [{Agent, fn -> :running end}, {Tay.Standalone.RuntimeMonitor, engine: @name}],
        strategy: :one_for_one,
        auto_shutdown: :any_significant
      )

    Process.unlink(supervisor)
    monitor = Process.monitor(supervisor)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    end)

    children = Map.new(Supervisor.which_children(supervisor), fn {id, pid, _, _} -> {id, pid} end)
    runtime_monitor = children[Tay.Standalone.RuntimeMonitor]

    for state <- [:ready, :recovering, :compacting, :draining, :drained, :stopped] do
      :ets.insert(@name, {:meta, %{metadata | status: %{state: state}}})
      send(runtime_monitor, :check)
      assert :sys.get_state(runtime_monitor) == @name
      assert Process.alive?(supervisor)
    end

    :ets.insert(@name, {:meta, %{metadata | status: %{state: :failed}}})
    send(runtime_monitor, :check)

    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}, 5_000
    refute Process.alive?(children[Agent])
  end
end
