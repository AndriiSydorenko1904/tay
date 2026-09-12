defmodule Tay.Execution.ClockTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Event.V1
  alias Tay.Execution.Clock

  defmodule FakeClock do
    @behaviour Clock
    @impl true
    def wall_ms, do: Process.get(:execution_wall, 0)
    @impl true
    def monotonic_ms, do: Process.get(:execution_monotonic, -1000)
  end

  test "defaults and injected wall/monotonic providers remain separate" do
    assert V1.time?(Clock.wall())
    assert V1.time?(Clock.wall(nil))
    assert is_integer(Clock.monotonic())
    assert is_integer(Clock.monotonic(nil))
    assert Clock.wall(FakeClock) == 0
    assert Clock.monotonic(FakeClock) == -1000
    Process.put(:execution_wall, 5000)
    Process.put(:execution_monotonic, -200)
    assert Clock.wall(FakeClock) == 5000
    assert Clock.monotonic(FakeClock) == -200
    Process.put(:execution_wall, 10)
    assert Clock.wall(FakeClock) == 10
    assert Clock.monotonic(FakeClock) == -200
  end

  test "forward/backward steps, equal due times, and the time-domain ceiling use bounded rechecks" do
    assert Clock.delay_until(2000, 0) == 1000
    assert Clock.delay_until(2000, 1999) == 1
    assert Clock.delay_until(2000, 2000) == 0
    assert Clock.delay_until(2000, 2001) == 0
    assert Clock.delay_until(2000, 0, 100) == 100
    assert Clock.delay_until(V1.max_time(), 0) == 1000
    assert Clock.delay_until(V1.max_time(), V1.max_time() - 1) == 1

    for {due, wall, wake} <- [{-1, 0, 1}, {0, -1, 1}, {0, 0, 0}, {0, 0, 1001}] do
      assert_raise ArgumentError, fn -> Clock.delay_until(due, wall, wake) end
    end

    Process.put(:execution_wall, V1.max_time() + 1)
    assert_raise ArgumentError, fn -> Clock.wall(FakeClock) end
    Process.put(:execution_monotonic, nil)
    assert_raise ArgumentError, fn -> Clock.monotonic(FakeClock) end
  end

  property "every accepted clock recheck delay is bounded and cannot imply wall-clock eligibility" do
    check all(
            due <- integer(0..V1.max_time()),
            wall <- integer(0..V1.max_time()),
            wake <- integer(1..1000)
          ) do
      delay = Clock.delay_until(due, wall, wake)
      assert delay >= 0 and delay <= wake
      assert delay == 0 == due <= wall
      assert delay == min(max(due - wall, 0), wake)
    end
  end
end
