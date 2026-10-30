defmodule Tay.Execution.RateLimiterTest do
  use ExUnit.Case, async: true
  alias Tay.Execution.RateLimiter, as: R

  test "queue and task windows compose, expire at the boundary and do not charge reads" do
    {:ok, policies} =
      R.normalize(
        [
          queues: %{"default" => %{limit: 2, interval_ms: 100}},
          tasks: %{"limited.v1" => %{limit: 1, interval_ms: 50}}
        ],
        %{"default" => :default}
      )

    limiter = R.new(policies)
    assert R.allowed?(limiter, "default", "limited.v1", -1000)
    limiter = R.consume(limiter, "default", "limited.v1", -1000)
    refute R.allowed?(limiter, "default", "limited.v1", -951)
    assert R.allowed?(limiter, "default", "other.v1", -951)
    assert R.allowed?(limiter, "default", "limited.v1", -950)
    limiter = R.consume(limiter, "default", "other.v1", -950)
    refute R.allowed?(limiter, "default", "limited.v1", -949)
    assert R.allowed?(limiter, "default", "limited.v1", -900)
    assert R.allowed?(R.new(policies), "default", "limited.v1", -949)
  end

  test "policy configuration rejects unknown queues, duplicate keys and unbounded or malformed values" do
    for options <- [
          [queues: %{"missing" => %{limit: 1, interval_ms: 100}}],
          [tasks: %{"task.v1" => %{limit: 0, interval_ms: 100}}],
          [tasks: %{"task.v1" => %{limit: true, interval_ms: 100}}],
          [tasks: %{"task.v1" => %{limit: 1, interval_ms: 0}}],
          [tasks: %{"task.v1" => %{limit: 1, interval_ms: 86_400_001}}],
          [queues: %{}, queues: %{}],
          [unknown: %{}],
          [tasks: []],
          %{}
        ] do
      assert {:error, :invalid_rate_limits} = R.normalize(options, %{"default" => :default})
    end
  end
end
