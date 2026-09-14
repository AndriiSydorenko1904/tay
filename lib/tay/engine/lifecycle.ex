defmodule Tay.Engine.Lifecycle do
  @moduledoc false
  use GenServer
  alias Tay.Engine.Admission
  alias Tay.Storage.Writer
  alias Tay.Execution.LocalFence
  alias Tay.Engine.Operations
  alias Tay.Error

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: config.name)

  def init(config) do
    table = :ets.new(config.name, [:named_table, :public, :set, write_concurrency: true])
    for slot <- 1..config.client_slots, do: :ets.insert(table, {slot, nil, nil, :free, 0})
    :ets.insert(table, {:operation, nil, nil, :free, 0})

    meta = %{
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
     %{
       table: table,
       config: config,
       root: hd(Process.get(:"$ancestors")),
       operation: nil,
       meta: meta,
       engine: nil,
       writer: nil,
       runtime: nil,
       fence: nil,
       monitors: %{},
       permits: %{}
     }}
  end

  def handle_call({:attach_runtime, runtime}, {parent, _}, %{runtime: nil} = s) do
    if parent == hd(Process.get(:"$ancestors")) do
      monitor = Process.monitor(runtime)
      {:reply, :ok, %{s | runtime: runtime, monitors: Map.put(s.monitors, monitor, :runtime)}}
    else
      {:reply, {:error, :invalid_runtime_owner}, s}
    end
  end

  def handle_call(:runtime, {engine, _}, %{engine: engine} = s), do: {:reply, s.runtime, s}
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

  def handle_call({:attach_writer, writer}, {engine, _}, %{engine: engine, writer: nil} = s) do
    monitor = Process.monitor(writer)
    {:reply, :ok, %{s | writer: writer, monitors: Map.put(s.monitors, monitor, :writer)}}
  end

  def handle_call({:ready, snapshot}, {engine, _}, %{engine: engine} = s) do
    fence_live = if is_nil(s.fence), do: is_nil(s.runtime), else: LocalFence.live?(s.fence)

    if s.meta.status.state == :recovering and Process.alive?(s.writer) and fence_live do
      s = publish(s, Map.merge(snapshot, %{state: :ready, durability: s.meta.status.durability}))
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

  def handle_call({:reserve, generation, {slot, token}}, {owner, _}, s) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, ^owner, :claimed, expires} = old] ->
        if admission_ready?(s, generation) and System.monotonic_time(:millisecond) < expires do
          monitor = Process.monitor(owner)
          true = Admission.cas(s.table, old, {slot, token, owner, :reserved, expires})
          permits = Map.put(s.permits, {slot, token}, monitor)

          {:reply, :ok,
           %{s | permits: permits, monitors: Map.put(s.monitors, monitor, {:owner, slot, token})}}
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
          send(s.engine, {:command, generation, {slot, token}, payload, from})
          {:noreply, s}
        else
          {:reply, {:error, Tay.Error.new(:unavailable, :revoked)}, release(s, slot, token)}
        end

      _ ->
        {:reply, {:error, Tay.Error.new(:unavailable, :invalid_permit)}, s}
    end
  end

  def handle_call({:operation, generation, token, kind, force, deadline}, {owner, _} = from, s)
      when kind in [:stop, :restart, :compact] and is_boolean(force) and is_integer(deadline) do
    case :ets.lookup(s.table, :operation) do
      [{:operation, ^token, ^owner, :claimed, ^deadline} = old] ->
        if s.operation == nil and generation == s.meta.generation and
             System.monotonic_time(:millisecond) < deadline and
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

          operation = %{
            token: token,
            kind: kind,
            force: force,
            from: from,
            timer: timer,
            phase: :draining,
            driver: nil,
            monitor: nil,
            owner: owner,
            deadline: deadline,
            stats: nil
          }

          close_now = force or s.meta.status.state in [:stopped, :failed]

          s =
            if close_now,
              do: %{s | operation: operation},
              else:
                %{s | operation: operation}
                |> publish(Map.merge(s.meta.status, %{state: :draining}))

          if close_now do
            {:noreply, begin_closing(s)}
          else
            send(s.engine, {:lifecycle_drain, generation, token, self()})
            {:noreply, s}
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
    operation = %{s.operation | phase: :starting}
    :ets.insert(s.table, {:operation, token, operation.owner, :starting, operation.deadline})
    {:reply, :ok, %{s | operation: operation}}
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_lifecycle_request}, s}

  def handle_info({:completed, engine, slot, token, snapshot}, %{engine: engine} = s) do
    s =
      if s.meta.status.state in [:ready, :draining, :drained],
        do: publish(s, Map.merge(s.meta.status, snapshot)),
        else: s

    {:noreply, release(s, slot, token)}
  end

  def handle_info({:execution_snapshot, engine, token, snapshot}, %{engine: engine} = s) do
    s =
      if s.meta.status.state in [:ready, :draining, :drained],
        do: publish(s, Map.merge(s.meta.status, snapshot)),
        else: s

    send(engine, {:execution_snapshot_ack, token})
    {:noreply, s}
  end

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

  def handle_info({Writer, writer, event}, %{writer: writer, operation: %{phase: :closing}} = s)
      when event in [:poisoned, :closed], do: {:noreply, s}

  def handle_info({Writer, writer, event}, %{writer: writer} = s)
      when event in [:poisoned, :closed],
      do: {:noreply, revoke(s, :writer_unavailable)}

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.get(s.monitors, ref) do
      component when component in [:engine, :writer, :runtime, :fence] ->
        if match?(%{phase: :closing}, s.operation),
          do: {:noreply, s},
          else: {:noreply, revoke(s, :generation_lost)}

      :operation_driver ->
        next = revoke(s, :lifecycle_driver_lost)

        {:noreply,
         finish_operation(
           next,
           {:error, Error.new(:unknown_outcome, :lifecycle_driver_lost, nil, s.operation.kind)}
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

  def handle_info(
        {:operation_drained, engine, token},
        %{engine: engine, operation: %{token: token, phase: :draining} = operation} = s
      ) do
    # A delayed timer delivery is not extra authorization to start shutdown
    # after the graceful request's monotonic deadline.
    if System.monotonic_time(:millisecond) < operation.deadline do
      if operation.kind == :compact do
        send(engine, {:lifecycle_compact, s.meta.generation, token, self(), operation.deadline})
        {:noreply, %{s | operation: %{operation | phase: :compacting}}}
      else
        {:noreply, begin_closing(s)}
      end
    else
      {:noreply,
       finish_operation(
         s,
         {:error, Error.new(:timeout, :draining, nil, operation.kind)}
       )}
    end
  end

  def handle_info(
        {:compaction_result, engine, token, {:ok, stats}},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting} = op} = s
      ) do
    {:noreply, begin_closing(%{s | operation: %{op | stats: stats}})}
  end

  def handle_info(
        {:compaction_result, engine, token, {:error, reason}},
        %{engine: engine, operation: %{token: token, kind: :compact, phase: :compacting}} = s
      ) do
    {:noreply,
     revoke(
       finish_operation(
         s,
         {:error, Error.new(:unknown_outcome, {:compaction_failed, reason}, nil, :compact)}
       ),
       :compaction_failed
     )}
  end

  def handle_info({:operation_deadline, token}, %{operation: %{token: token} = operation} = s) do
    if operation.phase == :draining do
      {:noreply,
       finish_operation(
         s,
         {:error, Error.new(:timeout, :draining, nil, operation.kind)}
       )}
    else
      if operation.from,
        do:
          GenServer.reply(
            operation.from,
            {:error, Error.new(:unknown_outcome, :lifecycle_in_progress, nil, operation.kind)}
          )

      {:noreply, %{s | operation: %{operation | from: nil}}}
    end
  end

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

        {:compact, :ok} ->
          if s.meta.status.state == :ready and Process.alive?(s.engine) and
               Process.alive?(s.writer) and runtime_live?(s) do
            {s, {:ok, operation.stats}}
          else
            {revoke(s, :compaction_restart_failed),
             {:error, Error.new(:unknown_outcome, :compaction_restart_failed, nil, :compact)}}
          end

        _ ->
          {revoke(s, :lifecycle_failed),
           {:error, Error.new(:unavailable, :lifecycle_failed, nil, operation.kind)}}
      end

    {:noreply, finish_operation(s, reply)}
  end

  def handle_info(:reap, s) do
    now = System.monotonic_time(:millisecond)

    for slot <- 1..s.meta.slots do
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

  def handle_info(_, s), do: {:noreply, s}

  defp ready?(s, generation),
    do: s.meta.generation == generation and s.meta.status.state in [:ready, :draining, :drained]

  defp admission_ready?(s, generation),
    do: s.operation == nil and s.meta.generation == generation and s.meta.status.state == :ready

  defp runtime_live?(%{config: %{execution: false}, runtime: nil, fence: nil}), do: true

  defp runtime_live?(%{runtime: runtime, fence: fence})
       when is_pid(runtime) and not is_nil(fence),
       do: Process.alive?(runtime) and LocalFence.live?(fence)

  defp runtime_live?(_), do: false

  defp publish(s, status) do
    meta = %{s.meta | status: status}
    :ets.insert(s.table, {:meta, meta})
    %{s | meta: meta}
  end

  defp release(s, slot, token) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, _, _, _}] -> :ets.insert(s.table, {slot, nil, nil, :free, 0})
      _ -> :ok
    end

    {ref, permits} = Map.pop(s.permits, {slot, token})
    if ref, do: Process.demonitor(ref, [:flush])
    %{s | permits: permits, monitors: Map.delete(s.monitors, ref)}
  end

  defp begin_closing(s) do
    operation = %{s.operation | phase: :closing}

    :ets.insert(
      s.table,
      {:operation, operation.token, operation.owner, :closing, operation.deadline}
    )

    s = publish(%{s | operation: operation}, Map.merge(s.meta.status, %{state: :stopping}))
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

  defp finish_operation(s, reply) do
    operation = s.operation
    if operation.timer, do: Process.cancel_timer(operation.timer)
    :ets.insert(s.table, {:operation, nil, nil, :free, 0})
    if operation.from, do: GenServer.reply(operation.from, reply)
    if operation.monitor, do: Process.demonitor(operation.monitor, [:flush])
    %{s | operation: nil, monitors: Map.delete(s.monitors, operation.monitor)}
  end

  defp revoke(s, reason) do
    already_failed = s.meta.status.state == :failed
    s = publish(s, Map.merge(s.meta.status, %{state: :failed, reason: reason}))

    s =
      if match?(%{phase: :draining}, s.operation) do
        finish_operation(
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

    s
  end

  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_generation)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :generation_failed)
end
