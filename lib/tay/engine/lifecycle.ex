defmodule Tay.Engine.Lifecycle do
  @moduledoc false
  use GenServer
  alias Tay.Engine.Admission
  alias Tay.Storage.Writer

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: config.name)

  def init(config) do
    table = :ets.new(config.name, [:named_table, :public, :set, write_concurrency: true])
    for slot <- 1..config.client_slots, do: :ets.insert(table, {slot, nil, nil, :free, 0})

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
    {:ok, %{table: table, meta: meta, engine: nil, writer: nil, monitors: %{}, permits: %{}}}
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
    if s.meta.status.state == :recovering and Process.alive?(s.writer) do
      s = publish(s, Map.merge(snapshot, %{state: :ready, durability: s.meta.status.durability}))
      {:reply, :ok, s}
    else
      {:reply, {:error, :revoked}, s}
    end
  end

  def handle_call({:reserve, generation, {slot, token}}, {owner, _}, s) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, ^owner, :claimed, expires} = old] ->
        if ready?(s, generation) and System.monotonic_time(:millisecond) < expires do
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
        if ready?(s, generation) do
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

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_lifecycle_request}, s}

  def handle_info({:completed, engine, slot, token, snapshot}, %{engine: engine} = s) do
    s =
      if s.meta.status.state == :ready,
        do: publish(s, Map.merge(s.meta.status, snapshot)),
        else: s

    {:noreply, release(s, slot, token)}
  end

  def handle_info({:cancel_reservation, owner, {slot, token}}, s) do
    case :ets.lookup(s.table, slot) do
      [{^slot, ^token, ^owner, stage, _}] when stage in [:claimed, :reserved] ->
        {:noreply, release(s, slot, token)}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({Writer, writer, event}, %{writer: writer} = s)
      when event in [:poisoned, :closed],
      do: {:noreply, revoke(s, :writer_unavailable)}

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.get(s.monitors, ref) do
      component when component in [:engine, :writer] ->
        {:noreply, revoke(s, :generation_lost)}

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

    for slot <- 1..s.meta.slots do
      case :ets.lookup(s.table, slot) do
        [{^slot, _, owner, :claimed, expires} = old] ->
          if expires <= now or not Process.alive?(owner),
            do: Admission.cas(s.table, old, {slot, nil, nil, :free, 0})

        _ ->
          :ok
      end
    end

    Process.send_after(self(), :reap, 100)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp ready?(s, generation),
    do: s.meta.generation == generation and s.meta.status.state == :ready

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

  defp revoke(s, reason) do
    s = publish(s, Map.merge(s.meta.status, %{state: :failed, reason: reason}))
    # Gate closes before potentially slow Writer/helper cleanup. Killing Engine
    # removes all private ETS and tears down its linked temporary Writer.
    if is_pid(s.engine) and Process.alive?(s.engine), do: Process.exit(s.engine, :kill)
    s
  end

  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_generation)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :generation_failed)
end
