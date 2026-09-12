defmodule Tay.Execution.Clock do
  @moduledoc """
  Runtime clock boundary. Wall time determines eligibility; monotonic time only
  measures callback deadlines and bounded wakeups. Neither is called by replay.
  A trusted test provider may implement the same two zero-argument callbacks.
  """
  alias Tay.Event.V1

  @callback wall_ms() :: non_neg_integer()
  @callback monotonic_ms() :: integer()

  def wall_ms, do: System.system_time(:millisecond)
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  def wall(provider \\ __MODULE__) do
    value = (provider || __MODULE__).wall_ms()

    if V1.time?(value),
      do: value,
      else: raise(ArgumentError, "execution wall clock outside Event v1 time domain")
  end

  def monotonic(provider \\ __MODULE__) do
    value = (provider || __MODULE__).monotonic_ms()

    if is_integer(value),
      do: value,
      else: raise(ArgumentError, "execution monotonic clock must return an integer")
  end

  @doc "Bounds a wall-time recheck; a timer is not authorization to execute."
  def delay_until(due, wall, wake_ms \\ 1000) do
    if V1.time?(due) and V1.time?(wall) and is_integer(wake_ms) and wake_ms in 1..1000,
      do: min(max(due - wall, 0), wake_ms),
      else: raise(ArgumentError, "invalid execution wakeup bounds")
  end
end
