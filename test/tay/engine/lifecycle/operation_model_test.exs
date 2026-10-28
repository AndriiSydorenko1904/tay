defmodule Tay.Engine.Lifecycle.OperationModelTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Engine.Lifecycle
  alias Tay.Engine.Lifecycle.{Operation, State}

  defp operation(kind, phase, from \\ {self(), make_ref()}) do
    %Operation{
      kind: kind,
      phase: phase,
      token: make_ref(),
      deadline: 25,
      owner: self(),
      from: from,
      force: false,
      cancel_flag: :atomics.new(1, [])
    }
  end

  defp state(operation) do
    table = :ets.new(:operation_model, [:set])

    :ets.insert(
      table,
      {:operation, operation.token, operation.owner, :submitted, operation.deadline}
    )

    %State{
      table: table,
      root: self(),
      config: %{compaction: %{terminal_retention: {:hours, 24}}},
      meta: %{generation: make_ref(), status: %{state: :compacting, durability: :write}},
      engine: self(),
      operation: operation
    }
  end

  test "a drain deadline retires only its operation and cannot start a late shutdown" do
    for kind <- [:stop, :restart, :compact] do
      from = {self(), make_ref()}
      operation = operation(kind, :draining, from)
      state = state(operation)

      assert {:noreply, next} =
               Lifecycle.handle_info({:operation_deadline, operation.token}, state)

      {_, ref} = from
      assert_receive {^ref, {:error, %{kind: :timeout, reason: :draining, operation: ^kind}}}
      assert next.operation == nil
      assert [{:operation, nil, nil, :free, 0}] = :ets.lookup(state.table, :operation)

      assert {:noreply, ^next} =
               Lifecycle.handle_info({:operation_drained, self(), operation.token}, next)

      assert {:noreply, ^next} =
               Lifecycle.handle_info({:operation_deadline, operation.token}, next)

      refute_receive {^ref, _}
    end
  end

  test "post-effect expiry reports unknown once and retains the administrative slot" do
    for {kind, phase} <- [
          {:stop, :closing},
          {:restart, :closing},
          {:restart, :starting},
          {:compact, :compacting},
          {:compact, :closing},
          {:compact, :starting}
        ] do
      from = {self(), make_ref()}
      operation = operation(kind, phase, from)
      state = state(operation)

      assert {:noreply, next} =
               Lifecycle.handle_info({:operation_deadline, operation.token}, state)

      {_, ref} = from
      assert_receive {^ref, {:error, %{kind: :unknown_outcome, reason: :lifecycle_in_progress}}}
      assert next.operation.phase == phase
      assert next.operation.from == nil
      assert :ets.lookup(state.table, :operation) == :ets.lookup(next.table, :operation)
      assert [{:operation, token, _, :submitted, 25}] = :ets.lookup(next.table, :operation)
      assert token == operation.token

      assert {:noreply, ^next} =
               Lifecycle.handle_info({:operation_deadline, operation.token}, next)

      refute_receive {^ref, _}
    end
  end

  test "late online completion releases the slot without replying twice" do
    from = {self(), make_ref()}
    operation = operation(:compact, :compacting, from)
    state = state(operation)
    {:noreply, expired} = Lifecycle.handle_info({:operation_deadline, operation.token}, state)
    {_, ref} = from
    assert_receive {^ref, {:error, %{kind: :unknown_outcome}}}

    assert {:noreply, completed} =
             Lifecycle.handle_info(
               {:online_compaction_result, self(), operation.token,
                {:ok, %{terminal_retention: {:hours, 24}}}},
               expired
             )

    assert completed.operation == nil
    assert completed.meta.status.state == :ready
    assert [{:operation, nil, nil, :free, 0}] = :ets.lookup(completed.table, :operation)
    refute_receive {^ref, _}
  end

  test "a late policy drain cancels the fence through the same deadline path" do
    operation = %{
      operation(:compact, :draining)
      | deadline: System.monotonic_time(:millisecond) - 1
    }

    state = %{state(operation) | policy: self()}

    assert {:noreply, next} =
             Lifecycle.handle_info({:operation_drained, self(), operation.token}, state)

    assert next.operation == nil
    assert next.meta.status.state == :ready
    generation = state.meta.generation
    token = operation.token
    assert_receive {:policy_drain_cancel, ^generation, ^token, _}
    refute_receive {:lifecycle_compact, _, _, _, _, _, _, _}
  end

  test "stale tokens and wrong senders never advance or release a newer operation" do
    for kind <- [:stop, :restart, :compact],
        phase <- [:draining, :compacting, :closing, :starting] do
      operation = operation(kind, phase)
      state = state(operation)
      stale = make_ref()
      wrong = spawn(fn -> :ok end)

      for message <- [
            {:operation_deadline, stale},
            {:operation_drained, self(), stale},
            {:operation_drained, wrong, operation.token},
            {:online_compaction_result, wrong, operation.token, {:ok, %{}}},
            {:operation_result, wrong, stale, :ok}
          ] do
        assert {:noreply, ^state} = Lifecycle.handle_info(message, state)
      end
    end
  end

  property "operation traces preserve the phase graph, deadline boundary and one-reply invariant" do
    check all(
            kind <- member_of([:stop, :restart, :compact]),
            actions <-
              list_of(
                tuple(
                  {member_of([
                     :drained,
                     :offline_fallback,
                     :close,
                     :starting,
                     :deadline,
                     :failure
                   ]), integer(0..5)}
                ),
                max_length: 100
              ),
            max_runs: 250
          ) do
      phase = if kind == :compact, do: :compacting, else: :draining
      real = %{operation: operation(kind, phase), time: 0, replies: []}
      model = %{kind: kind, phase: phase, pending: true, time: 0, replies: []}

      Enum.reduce(actions, {real, model}, fn {event, elapsed}, {real, model} ->
        real = %{real | time: real.time + elapsed}
        model = %{model | time: model.time + elapsed}
        real = actual_event(real, event)
        model = model_event(model, event)
        assert (real.operation && real.operation.phase) == model.phase
        assert (real.operation != nil and real.operation.from != nil) == model.pending
        assert real.replies == model.replies
        assert length(real.replies) <= 1
        {real, model}
      end)
    end
  end

  defp actual_event(%{operation: nil} = state, _), do: state
  defp actual_event(state, :deadline) when state.time < 25, do: state
  defp actual_event(state, :deadline), do: actual_expire(state)

  defp actual_event(state, :failure) do
    expected = if state.operation.phase == :draining, do: :unavailable, else: :unknown_outcome
    assert Operation.failure(state.operation, :opaque).kind == expected
    state
  end

  defp actual_event(state, event) do
    case Operation.advance(state.operation, event, state.time) do
      {:ok, operation} -> %{state | operation: operation}
      {:error, :draining_deadline} -> actual_expire(state)
      {:error, :invalid_operation_transition} -> state
    end
  end

  defp actual_expire(state) do
    case Operation.expire(state.operation) do
      {:finish, {:error, error}} ->
        replies = if state.operation.from, do: state.replies ++ [error.kind], else: state.replies
        %{state | operation: nil, replies: replies}

      {:pending, operation, notification} ->
        replies = if notification, do: state.replies ++ [:unknown_outcome], else: state.replies
        %{state | operation: operation, replies: replies}
    end
  end

  # Independent reference semantics: drained administrative work can close;
  # compact first needs its offline build; starting is only for replacements.
  defp model_event(%{phase: nil} = model, _), do: model
  defp model_event(model, :failure), do: model
  defp model_event(model, :deadline) when model.time < 25, do: model
  defp model_event(model, :deadline), do: model_expire(model)

  defp model_event(%{phase: :draining} = model, :drained) do
    if model.time >= 25 do
      model_expire(model)
    else
      %{model | phase: if(model.kind == :compact, do: :compacting, else: :closing)}
    end
  end

  defp model_event(%{kind: :compact, phase: :compacting} = model, :offline_fallback),
    do: %{model | phase: :draining}

  defp model_event(model, :close) do
    allowed = if model.kind == :compact, do: :compacting, else: :draining
    if model.phase == allowed, do: %{model | phase: :closing}, else: model
  end

  defp model_event(%{phase: :closing} = model, :starting) when model.kind != :stop,
    do: %{model | phase: :starting}

  defp model_event(model, _), do: model

  defp model_expire(model) do
    kind = if model.phase == :draining, do: :timeout, else: :unknown_outcome
    replies = if model.pending, do: model.replies ++ [kind], else: model.replies

    %{
      model
      | phase: if(model.phase == :draining, do: nil, else: model.phase),
        pending: false,
        replies: replies
    }
  end
end
