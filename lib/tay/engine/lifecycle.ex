defmodule Tay.Engine.Lifecycle do
  @moduledoc false
  use GenServer
  alias Tay.Engine.Lifecycle.{CommandDelivery, State, Operation, Status}
  alias Tay.Engine.Lifecycle.Operations, as: OperationControl
  alias Tay.Engine.Admission
  alias Tay.Storage.Writer
  alias Tay.Execution.LocalFence
  alias Tay.Error

  # Client admission can be much wider than the amount of durable work that
  # should sit ahead of execution completions and queue demand in the Engine
  # mailbox. Lifecycle owns both the permits and command delivery, so this FIFO
  # window bounds that interference without changing public admission capacity.
  # Writer is the single serialized durable owner. Immediate modes deliver one
  # command at a time; configured strict group commit widens the delivery window
  # so the Engine can collect concurrent enqueue requests behind one barrier.
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: config.name)

  def init(config) do
    table = :ets.new(config.name, [:named_table, :public, :set, write_concurrency: true])

    for slot <- 1..config.client_slots,
        key <- [slot, {:schedule, slot}],
        do: :ets.insert(table, {key, nil, nil, :free, 0})

    :ets.insert(table, {:operation, nil, nil, :free, 0})

    meta = %{
      memory: Tay.State.Memory.new(config.max_state_bytes),
      guardian: self(),
      generation: make_ref(),
      slots: config.client_slots,
      slot_bytes: config.slot_bytes,
      timeout: config.caller_timeout,
      value_limits: config.value_limits,
      status: %{state: :recovering, durability: config.durability, jobs: 0, blocked_jobs: 0}
    }

    :ets.insert(table, {:meta, meta})
    Process.send_after(self(), :reap, 100)

    {:ok,
     %State{
       table: table,
       config: config,
       root: hd(Process.get(:"$ancestors")),
       operation: nil,
       policy: nil,
       shutdown_waiter: nil,
       meta: meta,
       engine: nil,
       writer: nil,
       runtime: nil,
       fence: nil,
       monitors: %{},
       permits: %{},
       delivery: CommandDelivery.new()
     }}
  end

  def handle_call({:attach_runtime, runtime}, {parent, _}, %{runtime: nil} = s) do
    if parent == s.root do
      monitor = Process.monitor(runtime)
      {:reply, :ok, %{s | runtime: runtime, monitors: Map.put(s.monitors, monitor, :runtime)}}
    else
      {:reply, {:error, :invalid_runtime_owner}, s}
    end
  end

  def handle_call(:runtime, {engine, _}, %{engine: engine} = s), do: {:reply, s.runtime, s}

  def handle_call({:attach_policy, policy}, {policy, _}, %{policy: nil} = s) do
    {:reply, :ok, %{s | policy: policy}}
  end

  def handle_call(:policy_shutdown, {policy, _} = from, %{policy: policy} = s) do
    if match?(%{kind: :compact}, s.operation), do: :atomics.put(s.operation.cancel_flag, 1, 1)

    if match?(%{kind: :compact, phase: :compacting}, s.operation),
      do: {:noreply, %{s | shutdown_waiter: from}},
      else: {:reply, :ok, s}
  end

  def handle_call(:fence, {engine, _}, %{engine: engine} = s), do: {:reply, s.fence, s}

  def handle_call({:attach_fence, lease}, {engine, _}, %{engine: engine, fence: nil} = s) do
    monitor = Process.monitor(LocalFence.guard(lease))
    {:reply, :ok, %{s | fence: lease, monitors: Map.put(s.monitors, monitor, :fence)}}
  end

  def handle_call({:execution_child, generation, relay, task}, {relay, _}, s) do
    result =
      if s.fence && ready?(s, generation),
        do: LocalFence.register(s.fence, relay, task),
        else: {:error, :revoked}

    {:reply, result, s}
  end

  def handle_call({:execution_child_dead, generation, relay, task}, {relay, _}, s) do
    result =
      if s.fence && generation == s.meta.generation,
        do: LocalFence.dead(s.fence, relay, task),
        else: {:error, :revoked}

    {:reply, result, s}
  end

  def handle_call({:execution_owner_live, generation, engine}, _, %{engine: engine} = s) do
    live =
      ready?(s, generation) and not is_nil(s.fence) and Process.alive?(engine) and
        Process.alive?(s.writer) and LocalFence.live?(s.fence)

    {:reply, if(live, do: :ok, else: {:error, :revoked}), s}
  end

  def handle_call(
        {:execution_live, generation, engine, relay, task},
        {caller, _},
        %{engine: engine} = s
      ) do
    live =
      caller in [relay, task] and ready?(s, generation) and not is_nil(s.fence) and
        Process.alive?(engine) and Process.alive?(s.writer) and
        LocalFence.live?(s.fence, relay, task)

    {:reply, if(live, do: :ok, else: {:error, :revoked}), s}
  end

  def handle_call({:attach_engine, engine}, {engine, _}, %{engine: nil} = s) do
    monitor = Process.monitor(engine)

    {:reply, {:ok, s.meta.generation},
     %{s | engine: engine, monitors: Map.put(s.monitors, monitor, :engine)}}
  end

  def handle_call(
        {:compaction_retention, engine, retention},
        {engine, _},
        %{engine: engine} = s
      ) do
    case Tay.Storage.V2.Retention.validate(retention) do
      :ok ->
        {:reply, :ok,
         %{s | config: OperationControl.put_compaction_retention(s.config, retention)}}

      _ ->
        {:reply, {:error, :invalid_retention}, s}
    end
  end

  def handle_call({:attach_writer, writer}, {engine, _}, %{engine: engine, writer: nil} = s) do
    monitor = Process.monitor(writer)
    {:reply, :ok, %{s | writer: writer, monitors: Map.put(s.monitors, monitor, :writer)}}
  end

  def handle_call({:inspection_writer, generation}, _from, s) do
    available =
      s.meta.generation == generation and
        (s.meta.status.state in [:ready, :draining, :drained] or
           (s.meta.status.state == :compacting and
              Map.get(s.meta.status, :phase) == :preparing)) and
        is_pid(s.writer) and Process.alive?(s.writer)

    {:reply, if(available, do: {:ok, s.writer}, else: {:error, :revoked}), s}
  end

  def handle_call({:ready, snapshot}, {engine, _}, %{engine: engine} = s) do
    fence_live = if is_nil(s.fence), do: is_nil(s.runtime), else: LocalFence.live?(s.fence)

    if s.meta.status.state == :recovering and Process.alive?(s.writer) and fence_live do
      s = publish(s, Map.merge(snapshot, %{state: :ready, durability: s.meta.status.durability}))
      if s.policy, do: send(s.policy, {:policy_generation, self()})
      send(self(), :release_startup_heap)
      {:reply, :ok, s}
    else
      {:reply, {:error, :revoked}, s}
    end
  end

  def handle_call({:reconciliation, snapshot}, {engine, _}, %{engine: engine} = s) do
    if s.meta.status.state == :recovering do
      status =
        Map.merge(snapshot, %{
          state: :recovering,
          phase: :reconciling,
          pending_reconciliation: snapshot.unsettled_executions,
          durability: s.meta.status.durability
        })

      {:reply, :ok, publish(s, status)}
    else
      {:reply, {:error, :revoked}, s}
    end
  end

  def handle_call({:reserve, generation, permit}, from, s),
    do: handle_call({:reserve, generation, permit, 0}, from, s)

  def handle_call({:reserve, generation, {slot, token}, bytes}, {owner, _}, s) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, ^owner, :claimed, expires} = old] ->
        if admission_ready?(s, generation) and System.monotonic_time(:millisecond) < expires do
          case Tay.State.Memory.reserve(s.meta.memory, bytes) do
            :ok ->
              monitor = Process.monitor(owner)
              true = Admission.cas(s.table, old, {slot, token, owner, :reserved, expires})
              permits = Map.put(s.permits, {slot, token}, monitor)

              {:reply, :ok,
               %{
                 s
                 | permits: permits,
                   monitors: Map.put(s.monitors, monitor, {:owner, slot, token}),
                   memory_permits: Map.put(s.memory_permits, {slot, token}, bytes)
               }}

            {:error, _} ->
              Admission.cas(s.table, old, {slot, nil, nil, :free, 0})
              {:reply, {:error, :retained_bytes}, s}
          end
        else
          Admission.cas(s.table, old, {slot, nil, nil, :free, 0})
          {:reply, {:error, :unavailable}, s}
        end

      _ ->
        {:reply, {:error, :invalid_permit}, s}
    end
  end

  def handle_call({:submit, generation, {slot, token}, payload}, {owner, _} = from, s) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, ^owner, :reserved, expires} = old] ->
        if admission_ready?(s, generation) do
          true = Admission.cas(s.table, old, {slot, token, owner, :submitted, expires})

          command = {generation, {slot, token}, payload, from}
          {:noreply, enqueue_command(s, command)}
        else
          {:reply, {:error, Tay.Error.new(:unavailable, :revoked)}, release(s, slot, token)}
        end

      _ ->
        {:reply, {:error, Tay.Error.new(:unavailable, :invalid_permit)}, s}
    end
  end

  def handle_call(message, from, s)
      when is_tuple(message) and elem(message, 0) in [:operation, :operation_starting],
      do: OperationControl.handle_call(message, from, s)

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_lifecycle_request}, s}

  def handle_cast({:policy_evaluate, policy, token}, %{policy: policy} = s) do
    case policy_ready(s) do
      :ok -> send(s.engine, {:policy_estimate, self(), policy, token})
      {:error, reason} -> send(policy, {:policy_estimate, token, {:error, reason}})
    end

    {:noreply, s}
  end

  def handle_cast({:automatic_compaction, policy, _, _, _, _} = message, %{policy: policy} = s),
    do: OperationControl.handle_cast(message, s)

  def handle_cast(_, s), do: {:noreply, s}

  def handle_info(
        {:policy_estimate_result, engine, policy, token, result},
        %{engine: engine, policy: policy} = s
      ) do
    result =
      case policy_ready(s) do
        :ok -> result
        error -> error
      end

    send(policy, {:policy_estimate, token, result})
    {:noreply, s}
  end

  def handle_info(
        {:completed, engine, slot, token, {owner, _} = from, reply, snapshot},
        %{engine: engine} = s
      ) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, ^owner, :submitted, _}] ->
        s =
          if s.meta.status.state in [:ready, :compacting, :draining, :drained, :migrating],
            do: publish(s, merge_runtime_snapshot(s, snapshot)),
            else: s

        # Releasing the exact submitted capability before replying is the
        # admission invariant. A caller that observes success can immediately
        # reuse capacity; stale generations/tokens never reach this branch.
        s = finish_command_delivery(s, {slot, token})
        s = release(s, slot, token)
        GenServer.reply(from, reply)
        send(engine, {:command_replied, self(), slot, token})
        {:noreply, dispatch_commands(s, engine_command_window(s))}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:execution_snapshot, engine, token, snapshot}, %{engine: engine} = s) do
    s =
      if s.meta.status.state in [:ready, :compacting, :draining, :drained, :migrating],
        do: publish(s, merge_runtime_snapshot(s, snapshot)),
        else: s

    send(engine, {:execution_snapshot_ack, token})
    {:noreply, s}
  end

  def handle_info({:command_yielded, engine, permit}, %{engine: engine} = s),
    do:
      {:noreply,
       s |> finish_command_delivery(permit) |> dispatch_commands(engine_command_window(s))}

  def handle_info({:execution_child_dead, generation, relay, task}, s) do
    if s.fence && generation == s.meta.generation, do: LocalFence.dead(s.fence, relay, task)
    {:noreply, s}
  end

  def handle_info(
        {LocalFence, _, :revoked, generation},
        %{meta: %{generation: generation}, operation: %{phase: :closing}} = s
      ),
      do: {:noreply, s}

  def handle_info({LocalFence, _, :revoked, generation}, %{meta: %{generation: generation}} = s),
    do: {:noreply, revoke(s, :execution_generation_lost)}

  def handle_info({:cancel_reservation, owner, {slot, token}}, s) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, ^owner, stage, _}] when stage in [:claimed, :reserved] ->
        {:noreply, release(s, slot, token)}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(message, s)
      when is_tuple(message) and
             elem(message, 0) in [
               :operation_source_changed,
               :operation_policy_draining,
               :online_compaction_unsupported,
               :online_compaction_switch_requested,
               :online_compaction_result,
               :operation_drained,
               :compaction_result,
               :operation_deadline,
               :cancel_operation_claim,
               :operation_result
             ],
      do: OperationControl.handle_info(message, s)

  def handle_info({Writer, writer, event}, %{writer: writer, operation: %{phase: :closing}} = s)
      when event in [:poisoned, :closed], do: {:noreply, s}

  def handle_info(
        {Writer, writer, :poisoned},
        %{writer: writer, operation: %{kind: :compact, phase: :compacting}} = s
      ),
      do: {:noreply, s}

  def handle_info({Writer, writer, event}, %{writer: writer} = s)
      when event in [:poisoned, :closed],
      do: {:noreply, revoke(s, :writer_unavailable)}

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.get(s.monitors, ref) do
      component
      when component in [:engine, :writer, :runtime, :fence] and
             is_map(s.operation) and s.operation.phase == :compacting ->
        next =
          OperationControl.finish_operation(
            s,
            {:error, Operation.failure(s.operation, {:generation_lost, component})}
          )

        {:noreply, revoke(next, :generation_lost)}

      component when component in [:engine, :writer, :runtime, :fence] ->
        if match?(%{phase: :closing}, s.operation),
          do: {:noreply, s},
          else: {:noreply, revoke(s, :generation_lost)}

      :operation_driver ->
        next = revoke(s, :lifecycle_driver_lost)

        {:noreply,
         OperationControl.finish_operation(
           next,
           {:error, Operation.failure(s.operation, :lifecycle_driver_lost)}
         )}

      {:owner, slot, token} ->
        # Owner was monitored BEFORE grant. Its submit and DOWN reach THIS same
        # recipient in signal order. Submitted work is never released by DOWN.
        case :ets.lookup(s.table, slot) do
          [{^slot, ^token, _, :reserved, _}] -> {:noreply, release(s, slot, token)}
          _ -> {:noreply, s}
        end

      nil ->
        {:noreply, s}
    end
  end

  def handle_info(:reap, s) do
    now = System.monotonic_time(:millisecond)

    for index <- 1..s.meta.slots, slot <- [index, {:schedule, index}] do
      case :ets.lookup(s.table, slot) do
        [{^slot, _, owner, :claimed, expires} = old] ->
          if expires <= now or not Process.alive?(owner),
            do: Admission.cas(s.table, old, {slot, nil, nil, :free, 0})

        _ ->
          :ok
      end
    end

    case :ets.lookup(s.table, :operation) do
      [{:operation, _, owner, :claimed, expires} = old] ->
        if expires <= now or not Process.alive?(owner),
          do: Admission.cas(s.table, old, {:operation, nil, nil, :free, 0})

      _ ->
        :ok
    end

    Process.send_after(self(), :reap, 100)
    {:noreply, s}
  end

  # Recovery and activation messages can temporarily copy the recovered
  # projection through the guardian. Once readiness has been published, keep
  # only the small steady-state lifecycle data instead of waiting for BEAM's
  # very high full-sweep threshold to reclaim the old heap.
  def handle_info(:release_startup_heap, s) do
    :erlang.garbage_collect()
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp ready?(s, generation),
    do:
      s.meta.generation == generation and
        s.meta.status.state in [:ready, :compacting, :draining, :drained]

  def policy_ready(s) do
    cond do
      s.operation != nil and s.operation.kind == :compact ->
        {:error, :busy}

      s.meta.status.state in [:recovering, :draining, :drained, :stopping, :stopped] ->
        {:error, s.meta.status.state}

      s.meta.status.state != :ready ->
        {:error, :unhealthy}

      s.operation != nil ->
        {:error, :busy}

      not is_pid(s.engine) or not is_pid(s.writer) ->
        {:error, :unhealthy}

      not Process.alive?(s.engine) or not Process.alive?(s.writer) or not runtime_live?(s) ->
        {:error, :unhealthy}

      true ->
        :ok
    end
  end

  defp admission_ready?(s, generation),
    do:
      s.meta.generation == generation and
        ((not match?(%{kind: :compact}, s.operation) and
            s.meta.status.state in [:ready, :draining, :drained]) or
           (match?(%{kind: :compact, phase: :compacting}, s.operation) and
              s.meta.status.state == :compacting and
              Map.get(s.meta.status, :phase) == :preparing))

  def runtime_live?(%{config: %{execution: false}, runtime: nil, fence: nil}), do: true

  def runtime_live?(%{runtime: runtime, fence: fence})
      when is_pid(runtime) and not is_nil(fence),
      do: Process.alive?(runtime) and LocalFence.live?(fence)

  def runtime_live?(_), do: false

  def publish(s, status) do
    meta = %{s.meta | status: status}
    :ets.insert(s.table, {:meta, meta})
    %{s | meta: meta}
  end

  defp merge_runtime_snapshot(s, snapshot) do
    merged = Map.merge(s.meta.status, snapshot)

    if match?(%{kind: :compact}, s.operation) do
      Map.merge(merged, Map.take(s.meta.status, [:state, :phase]))
    else
      merged
    end
  end

  defp release(s, slot, token) do
    {bytes, memory_permits} = Map.pop(s.memory_permits, {slot, token}, 0)
    Tay.State.Memory.release(s.meta.memory, bytes)
    s = %{s | memory_permits: memory_permits}

    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, _, _, _}] -> :ets.insert(s.table, {slot, nil, nil, :free, 0})
      _ -> :ok
    end

    {ref, permits} = Map.pop(s.permits, {slot, token})
    if ref, do: Process.demonitor(ref, [:flush])
    %{s | permits: permits, monitors: Map.delete(s.monitors, ref)}
  end

  defp enqueue_command(s, command) do
    %{s | delivery: CommandDelivery.enqueue(s.delivery, command)}
    |> dispatch_commands(engine_command_window(s))
  end

  defp dispatch_commands(s, limit) do
    case CommandDelivery.take(s.delivery, limit) do
      {:ok, {generation, permit, payload, from}, delivery} ->
        send(s.engine, {:command, generation, permit, payload, from})
        dispatch_commands(%{s | delivery: delivery}, limit)

      :empty ->
        s
    end
  end

  defp engine_command_window(%{config: %{durability: :sync} = config}) do
    batch = config.journal_batch
    if batch.max_events > 1 or batch.interval_ms > 0, do: config.client_slots, else: 1
  end

  defp engine_command_window(_), do: 1

  def flush_commands(s), do: dispatch_commands(s, CommandDelivery.flush_limit(s.delivery))

  defp finish_command_delivery(s, permit),
    do: %{s | delivery: CommandDelivery.complete(s.delivery, permit)}

  def revoke(s, reason) do
    if s.policy, do: send(s.policy, {:policy_generation, self()})
    already_failed = s.meta.status.state == :failed
    s = publish(s, Map.put(Status.transition(s.meta.status, :failed), :reason, reason))

    s =
      if match?(%{phase: :draining}, s.operation) do
        OperationControl.finish_operation(
          s,
          {:error, Error.new(:unavailable, :generation_lost, nil, s.operation.kind)}
        )
      else
        s
      end

    if s.fence, do: LocalFence.revoke(s.fence)
    # Gate closes before potentially slow Writer/helper cleanup. Killing Engine
    # removes all private ETS and tears down its linked temporary Writer.
    if is_pid(s.engine) and Process.alive?(s.engine), do: Process.exit(s.engine, :kill)

    if not already_failed and is_pid(s.runtime) and Process.alive?(s.runtime) do
      # Relays synchronously acknowledge task death through this guardian. Do
      # not block their recipient while waiting for the runtime to stop. The
      # independent local fence already denies a replacement generation.
      runtime = s.runtime
      spawn(fn -> Tay.Execution.Supervisor.stop_children(runtime) end)
    end

    %{
      s
      | delivery: CommandDelivery.new()
    }
  end

  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_generation)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :generation_failed)
end
