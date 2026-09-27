defmodule Tay.HTTP.WorkerSession do
  @moduledoc false
  use GenServer

  @idle_ms 60_000
  @poll_ms 20_000

  def start(capacity, owner), do: GenServer.start(__MODULE__, {capacity, owner})

  def claim(pid) do
    GenServer.call(pid, :claim, @poll_ms + 5_000)
  catch
    :exit, _ -> {:error, "unknown_worker"}
  end

  @impl true
  def init({capacity, owner}) do
    ref = make_ref()
    timer = Process.send_after(self(), {:idle, ref}, @idle_ms)

    {:ok,
     %{
       queue: :queue.new(),
       max_queue: capacity * 2 + 4,
       owner_monitor: Process.monitor(owner),
       waiter: nil,
       poll_timer: nil,
       poll_ref: nil,
       idle_ref: ref,
       idle_timer: timer
     }}
  end

  @impl true
  def handle_call(:claim, from, state) do
    state = renew(state)

    cond do
      state.waiter != nil ->
        {:reply, {:error, "claim_in_progress"}, state}

      true ->
        case :queue.out(state.queue) do
          {{:value, message}, queue} ->
            {:reply, {:ok, message}, %{state | queue: queue}}

          {:empty, _} ->
            ref = make_ref()
            timer = Process.send_after(self(), {:poll_timeout, ref}, @poll_ms)
            {:noreply, %{state | waiter: from, poll_timer: timer, poll_ref: ref}}
        end
    end
  end

  @impl true
  def handle_cast({:deliver, message}, state) do
    cond do
      state.waiter != nil ->
        Process.cancel_timer(state.poll_timer)
        GenServer.reply(state.waiter, {:ok, message})
        {:noreply, %{state | waiter: nil, poll_timer: nil, poll_ref: nil}}

      :queue.len(state.queue) < state.max_queue ->
        {:noreply, %{state | queue: :queue.in(message, state.queue)}}

      true ->
        {:stop, :delivery_overflow, state}
    end
  end

  def handle_cast(:close, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:poll_timeout, ref}, %{poll_ref: ref} = state) do
    GenServer.reply(state.waiter, :empty)
    {:noreply, %{state | waiter: nil, poll_timer: nil, poll_ref: nil}}
  end

  def handle_info({:idle, ref}, %{idle_ref: ref} = state), do: {:stop, :idle_timeout, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  defp renew(state) do
    Process.cancel_timer(state.idle_timer)
    ref = make_ref()
    %{state | idle_ref: ref, idle_timer: Process.send_after(self(), {:idle, ref}, @idle_ms)}
  end
end
