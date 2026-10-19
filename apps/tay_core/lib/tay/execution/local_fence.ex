defmodule Tay.Execution.LocalFence do
  @moduledoc """
  VM-local exclusion between execution generations of the same STORE_ID.

  Started lazily by explicit Engine startup under `Tay.Supervisor`; application
  startup itself remains storage-free. A lease is acquired before storage
  activation. Every callback task must be registered while still waiting and
  before it can receive execution authorization. The ledger contains only local
  process identities, bounded by the Engine's admitted execution credits.

  Revocation closes registration before killing tasks. A new lease is refused
  until every registered task is actually dead; neither an exited supervisor nor
  a released native lock proves callback death. Polling the bounded PID ledger
  avoids delivering arbitrary callback DOWN reasons to this process or Engine.

  A small `persistent_term` marker is installed before granting a lease and is
  erased only after proven retirement. This is ephemeral VM state, not durable
  metadata or a recovery ticket. If this process dies with an outstanding lease,
  a replacement deliberately refuses that STORE_ID with `:local_fence_lost` until
  a fresh VM: it cannot reconstruct a complete task ledger safely. Guardians
  monitor the exact fence PID and revoke their execution generation on its loss.
  No API clears an orphan marker or adopts an old lease.
  """
  use GenServer
  @poll_ms 10

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_child()
    end
  catch
    :exit, _ -> {:error, :local_fence_unavailable}
  end

  defp start_child do
    case Supervisor.start_child(Tay.Supervisor, {__MODULE__, []}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :already_present} -> restart_child()
      _ -> {:error, :local_fence_unavailable}
    end
  end

  defp restart_child do
    case Supervisor.restart_child(Tay.Supervisor, __MODULE__) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :running} ->
        case Process.whereis(__MODULE__) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> {:error, :local_fence_unavailable}
        end

      _ ->
        {:error, :local_fence_unavailable}
    end
  end

  def acquire(store_id, generation, engine, guardian, runtime) do
    with {:ok, fence} <- ensure_started(),
         do: call(fence, {:acquire, store_id, generation, engine, guardian, runtime})
  end

  def register(lease, relay, task), do: lease_call(lease, {:register, relay, task})
  def dead(lease, relay, task), do: lease_call(lease, {:dead, relay, task})
  def revoke(lease), do: lease_call(lease, :revoke)
  def live?(lease), do: lease_call(lease, :live) == true
  def live?(lease, relay, task), do: lease_call(lease, {:live, relay, task}) == true
  # Read-only exact-lease retirement evidence. A lost guard or an orphan marker
  # never becomes permission to forget a task or start another generation.
  def retired?({__MODULE__, fence, store_id, generation, token})
      when is_pid(fence) and is_binary(store_id) and is_reference(generation) and
             is_reference(token),
      do: call(fence, {:retired, store_id, generation, token})

  def retired?(_), do: {:error, :invalid_local_lease}
  def guard({__MODULE__, fence, _, _, _}) when is_pid(fence), do: fence
  def guard(_), do: nil

  defp lease_call({__MODULE__, fence, store_id, generation, token}, message)
       when is_pid(fence) and is_binary(store_id) and is_reference(generation) and
              is_reference(token),
       do: call(fence, {:lease, store_id, generation, token, message})

  defp lease_call(_, _), do: {:error, :invalid_local_lease}

  defp call(fence, message) do
    GenServer.call(fence, message, 5_000)
  catch
    :exit, _ -> {:error, :local_fence_lost}
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{leases: %{}, monitors: %{}, poll: nil}}
  end

  @impl true
  def handle_call({:acquire, store_id, generation, engine, guardian, runtime}, {caller, _}, s) do
    cond do
      caller != engine or not valid_store?(store_id) or not is_reference(generation) or
          not Enum.all?([engine, guardian, runtime], &local_alive?/1) ->
        {:reply, {:error, :invalid_local_lease}, s}

      Map.has_key?(s.leases, store_id) ->
        reason =
          if s.leases[store_id].phase == :revoked,
            do: :local_tasks_terminating,
            else: :local_generation_owned

        {:reply, {:error, reason}, s}

      :persistent_term.get(marker(store_id), nil) != nil ->
        {:reply, {:error, :local_fence_lost}, s}

      true ->
        token = make_ref()
        # Never grant first and record later: a creator can lose its reply or
        # this process can die at any instruction boundary.
        :persistent_term.put(marker(store_id), {self(), token})

        lease = %{
          generation: generation,
          token: token,
          engine: engine,
          guardian: guardian,
          runtime: runtime,
          phase: :active,
          tasks: %{},
          relays: %{},
          owner_refs: []
        }

        {owner_refs, monitors} =
          [engine, guardian, runtime]
          |> Enum.uniq()
          |> Enum.map_reduce(s.monitors, fn pid, monitors ->
            ref = Process.monitor(pid)
            {ref, Map.put(monitors, ref, {store_id, :owner, pid})}
          end)

        lease = %{lease | owner_refs: owner_refs}
        s = %{s | leases: Map.put(s.leases, store_id, lease), monitors: monitors}
        {:reply, {:ok, {__MODULE__, self(), store_id, generation, token}}, s}
    end
  end

  def handle_call({:lease, store_id, generation, token, message}, {caller, _}, s) do
    case Map.get(s.leases, store_id) do
      %{generation: ^generation, token: ^token} = lease ->
        lease_request(message, caller, store_id, lease, s)

      _ ->
        {:reply, {:error, :invalid_local_lease}, s}
    end
  end

  def handle_call({:retired, store_id, generation, token}, _, s) do
    result =
      case Map.get(s.leases, store_id) do
        %{generation: ^generation, token: ^token} ->
          false

        nil ->
          if :persistent_term.get(marker(store_id), nil) == nil,
            do: true,
            else: {:error, :local_fence_lost}

        _ ->
          {:error, :invalid_local_lease}
      end

    {:reply, result, s}
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_local_lease}, s}

  defp lease_request(:live, _, _store_id, lease, s),
    do: {:reply, active?(lease), s}

  defp lease_request({:live, relay, task}, _, _store_id, lease, s),
    do:
      {:reply,
       active?(lease) and Map.get(lease.tasks, task) == relay and local_alive?(relay) and
         local_alive?(task), s}

  defp lease_request({:register, relay, task}, caller, store_id, lease, s) do
    cond do
      caller not in [lease.guardian, relay] ->
        {:reply, {:error, :invalid_task_registration}, s}

      not active?(lease) ->
        {:reply, {:error, :local_tasks_terminating}, revoke_store(s, store_id)}

      not local_alive?(relay) or not local_alive?(task) ->
        {:reply, {:error, :invalid_task_registration}, s}

      Map.get(lease.tasks, task) == relay ->
        {:reply, :ok, s}

      Map.has_key?(lease.tasks, task) or Map.has_key?(lease.relays, relay) ->
        {:reply, {:error, :invalid_task_registration}, revoke_store(s, store_id)}

      true ->
        ref = Process.monitor(relay)

        lease = %{
          lease
          | tasks: Map.put(lease.tasks, task, relay),
            relays: Map.put(lease.relays, relay, ref)
        }

        {:reply, :ok,
         %{
           s
           | leases: Map.put(s.leases, store_id, lease),
             monitors: Map.put(s.monitors, ref, {store_id, :relay, relay})
         }}
    end
  end

  defp lease_request({:dead, relay, task}, caller, store_id, lease, s) do
    cond do
      caller not in [lease.guardian, relay] ->
        {:reply, {:error, :invalid_task_registration}, s}

      Map.get(lease.tasks, task) != relay ->
        {:reply, {:error, :invalid_task_registration}, s}

      local_alive?(task) ->
        {:reply, {:error, :task_still_alive}, s}

      true ->
        s = drop_task(s, store_id, task)
        {:reply, :ok, maybe_retire(s, store_id)}
    end
  end

  defp lease_request(:revoke, caller, store_id, lease, s) do
    if caller in [lease.engine, lease.guardian, lease.runtime],
      do: {:reply, :ok, revoke_store(s, store_id)},
      else: {:reply, {:error, :invalid_local_lease}, s}
  end

  defp lease_request(_, _, _, _, s), do: {:reply, {:error, :invalid_local_lease}, s}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    case Map.get(s.monitors, ref) do
      {store_id, _kind, _pid} -> {:noreply, revoke_store(s, store_id)}
      nil -> {:noreply, s}
    end
  end

  def handle_info(:poll, s) do
    s = %{s | poll: nil}

    s =
      Enum.reduce(s.leases, s, fn
        {store_id, %{phase: :revoked, tasks: tasks}}, acc ->
          acc =
            Enum.reduce(tasks, acc, fn {task, _relay}, inner ->
              if local_alive?(task), do: inner, else: drop_task(inner, store_id, task)
            end)

          maybe_retire(acc, store_id)

        _, acc ->
          acc
      end)

    {:noreply, arm_poll(s)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp revoke_store(s, store_id) do
    case Map.get(s.leases, store_id) do
      nil ->
        s

      %{phase: :revoked} ->
        # Guardian also revokes in response to our notification. Publish and
        # kill once; the already-armed death check completes retirement without
        # a Guardian -> fence -> Guardian notification loop.
        s

      lease ->
        # State is closed before any kill or retirement. No future registration
        # can race into the lease after the known task set has been checked.
        lease = %{lease | phase: :revoked}
        s = %{s | leases: Map.put(s.leases, store_id, lease)}
        send(lease.guardian, {__MODULE__, self(), :revoked, lease.generation})
        Enum.each(lease.tasks, fn {task, _} -> Process.exit(task, :kill) end)

        s =
          Enum.reduce(lease.tasks, s, fn {task, _}, acc ->
            if local_alive?(task), do: acc, else: drop_task(acc, store_id, task)
          end)

        s |> maybe_retire(store_id) |> arm_poll()
    end
  end

  defp drop_task(s, store_id, task) do
    lease = Map.fetch!(s.leases, store_id)
    {relay, tasks} = Map.pop(lease.tasks, task)
    {ref, relays} = Map.pop(lease.relays, relay)
    if ref, do: Process.demonitor(ref, [:flush])
    lease = %{lease | tasks: tasks, relays: relays}

    %{
      s
      | leases: Map.put(s.leases, store_id, lease),
        monitors: Map.delete(s.monitors, ref)
    }
  end

  defp maybe_retire(s, store_id) do
    case Map.get(s.leases, store_id) do
      %{phase: :revoked, tasks: tasks} = lease when map_size(tasks) == 0 ->
        Enum.each(lease.owner_refs, &Process.demonitor(&1, [:flush]))
        # An unexpected marker is never permission to erase another generation.
        if :persistent_term.get(marker(store_id), nil) == {self(), lease.token},
          do: :persistent_term.erase(marker(store_id))

        %{
          s
          | leases: Map.delete(s.leases, store_id),
            monitors: Map.drop(s.monitors, lease.owner_refs)
        }

      _ ->
        s
    end
  end

  defp arm_poll(s) do
    if s.poll == nil and Enum.any?(s.leases, fn {_, lease} -> lease.phase == :revoked end),
      do: %{s | poll: Process.send_after(self(), :poll, @poll_ms)},
      else: s
  end

  defp active?(lease),
    do:
      lease.phase == :active and
        Enum.all?([lease.engine, lease.guardian, lease.runtime], &local_alive?/1)

  defp local_alive?(pid),
    do: is_pid(pid) and node(pid) == node() and Process.alive?(pid)

  defp valid_store?(<<_::128>> = store_id), do: store_id != <<0::128>>
  defp valid_store?(_), do: false
  defp marker(store_id), do: {__MODULE__, :lease, store_id}

  @impl true
  def terminate(_, s) do
    # Shutdown attempts cleanup but never waits indefinitely in an OTP callback.
    # Any task not yet proven dead leaves its marker intact; process loss itself
    # causes each guardian to revoke. A fresh VM is the fail-closed escape hatch.
    Enum.each(s.leases, fn {store_id, lease} ->
      Enum.each(lease.tasks, fn {task, _} -> Process.exit(task, :kill) end)

      if Enum.all?(lease.tasks, fn {task, _} -> not local_alive?(task) end) and
           :persistent_term.get(marker(store_id), nil) == {self(), lease.token},
         do: :persistent_term.erase(marker(store_id))
    end)

    :ok
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_local_fence)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :local_fence_lost)
end
