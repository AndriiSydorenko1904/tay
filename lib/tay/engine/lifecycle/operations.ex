defmodule Tay.Engine.Lifecycle.Operations do
  @moduledoc """
  Administrative stop/restart/compaction coordination, executed in Lifecycle's
  owner process. Token correlation, timers, replies and generation replacement
  stay serialized with command admission; this module never starts an owner.
  """
  alias Tay.Engine.Admission
  alias Tay.Engine.Lifecycle.{CommandDelivery, Operation, Status}
  alias Tay.Engine.Operations
  alias Tay.Execution.LocalFence
  alias Tay.Error

  import Tay.Engine.Lifecycle,
    only: [publish: 2, policy_ready: 1, runtime_live?: 1, flush_commands: 1, revoke: 2]

  def handle_call({:operation, generation, token, kind, force, deadline}, from, s)
      when kind in [:stop, :restart, :compact] do
    handle_call({:operation, generation, token, kind, force, deadline, nil}, from, s)
  end

  def handle_call(
        {:operation, generation, token, kind, force, deadline, retention},
        from,
        s
      ) do
    handle_call({:operation, generation, token, kind, force, deadline, retention, nil}, from, s)
  end

  def handle_call(
        {:operation, generation, token, kind, force, deadline, retention, expected_source},
        {owner, _} = from,
        s
      )
      when kind in [:stop, :restart, :compact] and is_boolean(force) and is_integer(deadline) do
    retention = if is_nil(retention), do: s.config.compaction.terminal_retention, else: retention

    case :ets.lookup(s.table, :operation) do
      [{:operation, ^token, ^owner, :claimed, ^deadline} = old] ->
        if s.operation == nil and generation == s.meta.generation and
             System.monotonic_time(:millisecond) < deadline and
             Tay.Storage.V2.Retention.validate(retention) == :ok and
             if(kind == :compact,
               do: s.meta.status.state == :ready and not force,
               else:
                 s.meta.status.state in [:ready, :draining, :drained, :stopped, :failed] or force
             ) do
          true = Admission.cas(s.table, old, {:operation, token, owner, :submitted, deadline})

          timer =
            Process.send_after(
              self(),
              {:operation_deadline, token},
              max(deadline - System.monotonic_time(:millisecond), 0)
            )

          operation = %Operation{
            token: token,
            kind: kind,
            from: from,
            timer: timer,
            phase: if(kind == :compact, do: :compacting, else: :draining),
            driver: nil,
            monitor: nil,
            owner: owner,
            deadline: deadline,
            stats: nil,
            terminal_retention: retention,
            expected_source: expected_source,
            cancel_flag: :atomics.new(1, [])
          }

          close_now = force or s.meta.status.state in [:stopped, :failed]

          s =
            if close_now,
              do: %{s | operation: operation},
              else:
                %{s | operation: operation}
                |> publish(
                  Map.merge(s.meta.status, %{
                    state: if(kind == :compact, do: :compacting, else: :draining),
                    phase: if(kind == :compact, do: :preparing, else: :draining)
                  })
                )

          if close_now do
            {:noreply, begin_closing(s)}
          else
            if kind == :compact do
              send(
                s.engine,
                {:lifecycle_compact_online, generation, token, self(), deadline, retention,
                 expected_source, operation.cancel_flag}
              )

              {:noreply, s}
            else
              # Submitted calls predate this lifecycle fence. Deliver every one
              # in FIFO order before the drain signal so no acknowledged or
              # unknown-outcome mutation can fall outside the drained frontier.
              s = flush_commands(s)
              send(s.engine, {:lifecycle_drain, generation, token, self(), expected_source})
              {:noreply, s}
            end
          end
        else
          Admission.cas(s.table, old, {:operation, nil, nil, :free, 0})
          {:reply, {:error, Error.new(:unavailable, :operation_unavailable, nil, kind)}, s}
        end

      _ ->
        {:reply, {:error, Error.new(:unavailable, :invalid_operation_permit, nil, kind)}, s}
    end
  end

  def handle_call(
        {:operation_starting, token, driver},
        {driver, _},
        %{operation: %{token: token, driver: driver, phase: :closing}} = s
      ) do
    s = reset_generation(s)
    {:ok, operation} = Operation.advance(s.operation, :starting, now())
    :ets.insert(s.table, {:operation, token, operation.owner, :starting, operation.deadline})
    {:reply, :ok, %{s | operation: operation}}
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_lifecycle_request}, s}

  def handle_cast(
        {:automatic_compaction, policy, token, generation, source, reason},
        %{policy: policy} = s
      ) do
    deadline = System.monotonic_time(:millisecond) + 900_000
    from = {policy, {:compaction_policy, token}}

    with :ok <- policy_ready(s),
         true <- generation == s.meta.generation,
         true <-
           Admission.cas(
             s.table,
             {:operation, nil, nil, :free, 0},
             {:operation, token, policy, :claimed, deadline}
           ) do
      case handle_call(
             {:operation, generation, token, :compact, false, deadline, nil, source},
             from,
             s
           ) do
        {:noreply, next} ->
          Tay.Engine.CompactionEvents.emit(:automatic_compaction_started, reason)
          {:noreply, next}

        {:reply, reply, next} ->
          GenServer.reply(from, reply)
          {:noreply, next}
      end
    else
      {:error, reason} ->
        GenServer.reply(from, {:deferred, reason})
        {:noreply, s}

      false ->
        GenServer.reply(from, {:deferred, :busy})
        {:noreply, s}
    end
  end

  def handle_cast(_, s), do: {:noreply, s}

  def handle_info(
        {:operation_source_changed, engine, token},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :draining}} = s
      ) do
    s = publish(s, Status.transition(s.meta.status, :ready))
    {:noreply, finish_operation(s, {:deferred, :source_changed})}
  end

  def handle_info(
        {:operation_source_changed, engine, token},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting}} = s
      ) do
    s = publish(s, Status.transition(s.meta.status, :ready))
    {:noreply, finish_operation(s, {:deferred, :source_changed})}
  end

  def handle_info(
        {:operation_policy_draining, engine, token},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :draining}} = s
      ) do
    s = publish(s, Status.transition(s.meta.status, :draining))
    {:noreply, finish_operation(s, {:deferred, :draining})}
  end

  def handle_info(
        {:online_compaction_unsupported, engine, token},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting} = op} = s
      ) do
    {:ok, operation} = Operation.advance(op, :offline_fallback, now())

    s =
      publish(
        %{s | operation: operation},
        Map.merge(s.meta.status, %{state: :migrating, phase: :draining})
      )

    s = flush_commands(s)
    send(engine, {:lifecycle_drain, s.meta.generation, token, self(), operation.expected_source})
    {:noreply, s}
  end

  def handle_info(
        {:online_compaction_switch_requested, engine, token},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting}} = s
      ) do
    s = publish(s, Map.merge(s.meta.status, %{state: :compacting, phase: :switching}))
    s = flush_commands(s)
    send(engine, {:online_compaction_switch_ack, self(), token})
    {:noreply, s}
  end

  def handle_info(
        {:online_compaction_result, engine, token, {:ok, stats}},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting}} = s
      ) do
    s =
      s
      |> Map.update!(:config, &put_compaction_retention(&1, stats.terminal_retention))
      |> publish(Status.transition(s.meta.status, :ready))

    {:noreply, finish_operation(s, {:ok, stats})}
  end

  def handle_info(
        {:online_compaction_result, engine, token, {:error, reason}},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting}} = s
      ) do
    s = publish(s, Status.transition(s.meta.status, :ready))

    {:noreply,
     finish_operation(
       s,
       {:error, Error.new(:unknown_outcome, {:compaction_failed, reason}, nil, :compact)}
     )}
  end

  def handle_info(
        {:operation_drained, engine, token},
        %{engine: engine, operation: %{token: token, phase: :draining} = operation} = s
      ) do
    case Operation.advance(operation, :drained, now()) do
      {:ok, %{phase: :compacting} = next} ->
        send(
          engine,
          {:lifecycle_compact, s.meta.generation, token, self(), next.deadline,
           next.terminal_retention, next.expected_source, next.cancel_flag}
        )

        {:noreply, %{s | operation: next}}

      {:ok, %{phase: :closing} = next} ->
        {:noreply, close_generation(s, next)}

      {:error, :draining_deadline} ->
        expire_operation(s)
    end
  end

  def handle_info(
        {:compaction_result, engine, token, {:ok, stats}},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting} = op} = s
      ) do
    {:noreply, begin_closing(%{settled_shutdown(s) | operation: %{op | stats: stats}})}
  end

  def handle_info(
        {:compaction_result, engine, token, {:error, reason}},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting} = op} = s
      ) do
    # A pre-CURRENT failure may leave a candidate
    # intent, but it does not justify retiring the authoritative source. Close
    # this Writer and restart through the same locked recovery/rollback gate.
    # If that recovery fails, the normal restart failure path remains closed.
    {:noreply, begin_closing(%{settled_shutdown(s) | operation: %{op | stats: {:error, reason}}})}
  end

  def handle_info({:operation_deadline, token}, %{operation: %{token: token}} = s),
    do: expire_operation(s)

  def handle_info({:cancel_operation_claim, owner, token}, s) do
    case :ets.lookup(s.table, :operation) do
      [{:operation, ^token, ^owner, :claimed, _} = old] ->
        Admission.cas(s.table, old, {:operation, nil, nil, :free, 0})

      _ ->
        :ok
    end

    {:noreply, s}
  end

  def handle_info(
        {:operation_result, driver, token, result},
        %{operation: %{driver: driver, token: token} = operation} = s
      ) do
    {s, reply} =
      case {operation.kind, result} do
        {:stop, :ok} ->
          {stopped(s), :ok}

        {:stop, {:error, :ownership_unconfirmed}} ->
          {stopped(s), {:error, Error.new(:unavailable, :ownership_unconfirmed, nil, :stop)}}

        {:restart, :ok} ->
          if s.meta.status.state == :ready and Process.alive?(s.engine) and
               Process.alive?(s.writer) and runtime_live?(s) do
            {s, :ok}
          else
            {revoke(s, :restart_failed),
             {:error, Error.new(:unavailable, :restart_failed, nil, :restart)}}
          end

        {:restart, {:error, reason}} when reason in [:recovery_failed, :runtime_start_failed] ->
          {revoke(s, :lifecycle_failed),
           {:error, Error.new(:unavailable, :lifecycle_failed, nil, :restart)}}

        {:compact, :ok} ->
          if s.meta.status.state == :ready and Process.alive?(s.engine) and
               Process.alive?(s.writer) and runtime_live?(s) do
            reply =
              case operation.stats do
                {:error, reason} ->
                  {:error,
                   Error.new(:unknown_outcome, {:compaction_failed, reason}, nil, :compact)}

                stats ->
                  {:ok, stats}
              end

            {s, reply}
          else
            {revoke(s, :compaction_restart_failed),
             {:error, Error.new(:unknown_outcome, :compaction_restart_failed, nil, :compact)}}
          end

        _ ->
          {revoke(s, :lifecycle_failed),
           {:error, Operation.failure(operation, :lifecycle_failed)}}
      end

    {:noreply, finish_operation(s, reply)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp begin_closing(s) do
    {:ok, operation} = Operation.advance(s.operation, :close, now())
    close_generation(s, operation)
  end

  defp close_generation(s, %{phase: :closing} = operation) do
    :ets.insert(
      s.table,
      {:operation, operation.token, operation.owner, :closing, operation.deadline}
    )

    s = publish(%{s | operation: operation}, Status.transition(s.meta.status, :stopping))
    if s.fence, do: LocalFence.revoke(s.fence)
    if is_pid(s.engine) and Process.alive?(s.engine), do: Process.exit(s.engine, :kill)
    guardian = self()
    old = Map.take(s, [:engine, :writer, :runtime, :fence])

    {driver, monitor} =
      spawn_monitor(fn ->
        Operations.drive(guardian, s.root, s.config, operation.token, old, operation.kind)
      end)

    operation = %{operation | driver: driver, monitor: monitor}
    %{s | operation: operation, monitors: Map.put(s.monitors, monitor, :operation_driver)}
  end

  defp clear_generation(s) do
    if s.policy, do: send(s.policy, {:policy_generation, self()})

    Enum.each(s.monitors, fn {ref, kind} ->
      if kind != :operation_driver, do: Process.demonitor(ref, [:flush])
    end)

    for slot <- 1..s.meta.slots, do: :ets.insert(s.table, {slot, nil, nil, :free, 0})

    %{
      s
      | engine: nil,
        writer: nil,
        runtime: nil,
        fence: nil,
        permits: %{},
        delivery: CommandDelivery.new(),
        monitors: Map.filter(s.monitors, fn {_, kind} -> kind == :operation_driver end)
    }
  end

  defp stopped(s) do
    s = clear_generation(s)
    publish(s, %{state: :stopped, durability: s.config.durability, jobs: 0, blocked_jobs: 0})
  end

  defp reset_generation(s) do
    s = clear_generation(s)
    s = %{s | meta: %{s.meta | generation: make_ref()}}
    publish(s, %{state: :recovering, durability: s.config.durability, jobs: 0, blocked_jobs: 0})
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp expire_operation(s) do
    case Operation.expire(s.operation) do
      {:finish, reply} ->
        s =
          if s.operation.owner == s.policy do
            send(s.engine, {:policy_drain_cancel, s.meta.generation, s.operation.token, self()})
            publish(s, Status.transition(s.meta.status, :ready))
          else
            s
          end

        {:noreply, finish_operation(s, reply)}

      {:pending, operation, notification} ->
        if notification do
          {from, reply} = notification
          GenServer.reply(from, reply)
        end

        {:noreply, %{s | operation: operation}}
    end
  end

  def finish_operation(s, reply) do
    s = settled_shutdown(s)
    operation = s.operation
    if operation.timer, do: Process.cancel_timer(operation.timer)
    :ets.insert(s.table, {:operation, nil, nil, :free, 0})

    reply =
      if operation.owner == s.policy, do: Tay.Engine.CompactionEvents.result(reply), else: reply

    if operation.from, do: GenServer.reply(operation.from, reply)
    if operation.monitor, do: Process.demonitor(operation.monitor, [:flush])
    %{s | operation: nil, monitors: Map.delete(s.monitors, operation.monitor)}
  end

  defp settled_shutdown(s) do
    if s.shutdown_waiter, do: GenServer.reply(s.shutdown_waiter, :ok)
    %{s | shutdown_waiter: nil}
  end

  def put_compaction_retention(config, retention),
    do: %{
      config
      | compaction: %{
          config.compaction
          | terminal_retention: Tay.Storage.V2.Retention.persisted(retention)
        }
    }
end
