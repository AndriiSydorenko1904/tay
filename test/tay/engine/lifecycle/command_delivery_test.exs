defmodule Tay.Engine.Lifecycle.CommandDeliveryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Engine.Lifecycle.CommandDelivery, as: Delivery

  defp command(id, token \\ make_ref()),
    do: {:generation, {id, token}, {:job, id}, {self(), make_ref()}}

  defp permit({_generation, permit, _payload, _from}), do: permit

  test "FIFO and delivery windows survive yields and duplicate acknowledgements" do
    commands = Enum.map(1..4, &command/1)
    [first, second, third, fourth] = commands
    state = Enum.reduce(commands, Delivery.new(), &Delivery.enqueue(&2, &1))
    assert {:ok, ^first, state} = Delivery.take(state, 2)
    assert {:ok, ^second, state} = Delivery.take(state, 2)
    assert :empty = Delivery.take(state, 2)
    state = Delivery.complete(state, permit(first))
    assert {:ok, ^third, state} = Delivery.take(state, 2)
    state = Delivery.complete(state, permit(first))
    assert Delivery.active_count(state) == 2
    assert :empty = Delivery.take(state, 2)
    state = Delivery.complete(state, permit(second))
    assert {:ok, ^fourth, state} = Delivery.take(state, 2)
    assert Delivery.pending_count(state) == 0
  end

  test "an old permit cannot complete a newer command reusing the same slot" do
    old = command(1)
    newer = command(1)
    assert {:ok, ^old, state} = Delivery.new() |> Delivery.enqueue(old) |> Delivery.take(1)
    state = Delivery.complete(state, permit(old)) |> Delivery.enqueue(newer)
    assert {:ok, ^newer, state} = Delivery.take(state, 1)
    state = Delivery.complete(state, permit(old))
    assert Delivery.active_count(state) == 1
    assert :empty = Delivery.take(Delivery.enqueue(state, command(2)), 1)
  end

  test "a lifecycle drain can flush pending commands without losing active permits" do
    commands = Enum.map(1..5, &command/1)
    state = Enum.reduce(commands, Delivery.new(), &Delivery.enqueue(&2, &1))
    assert {:ok, first, state} = Delivery.take(state, 1)
    {flushed, state} = take_all(state, Delivery.flush_limit(state))
    assert [first | flushed] == commands
    assert Delivery.active_count(state) == 5
    assert Delivery.pending_count(state) == 0
    assert :empty = Delivery.take(state, 1)
  end

  property "arbitrary submission, acknowledgement, flush and reset traces match a FIFO model" do
    check all(
            actions <-
              list_of(member_of([:submit, :ack, :stale_ack, :flush, :reset]), max_length: 100),
            max_runs: 100
          ) do
      Enum.reduce(actions, {Delivery.new(), [], [], 0}, fn action,
                                                           {delivery, pending, active, id} ->
        {delivery, pending, active, id} =
          case action do
            :submit ->
              next = command(id)
              {Delivery.enqueue(delivery, next), pending ++ [next], active, id + 1}

            :ack when active != [] ->
              [first | rest] = active
              {Delivery.complete(delivery, permit(first)), pending, rest, id}

            :stale_ack ->
              {Delivery.complete(delivery, {-1, make_ref()}), pending, active, id}

            :reset ->
              {Delivery.new(), [], [], id}

            _ ->
              {delivery, pending, active, id}
          end

        limit = if action == :flush, do: length(active) + length(pending), else: 3
        capacity = max(limit - length(active), 0)
        {expected, remaining} = Enum.split(pending, capacity)
        {actual, delivery} = take_all(delivery, limit)
        assert actual == expected
        active = active ++ expected
        assert Delivery.active_count(delivery) == length(active)
        assert Delivery.pending_count(delivery) == length(remaining)
        {delivery, remaining, active, id}
      end)
    end
  end

  defp take_all(delivery, limit, collected \\ []) do
    case Delivery.take(delivery, limit) do
      {:ok, command, next} -> take_all(next, limit, [command | collected])
      :empty -> {Enum.reverse(collected), delivery}
    end
  end
end
