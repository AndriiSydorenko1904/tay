defmodule Tay.Execution.Queue do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def wake(pid), do: GenServer.cast(pid, :wake)
  def acknowledged(pid, token, delay), do: GenServer.cast(pid, {:ack, token, delay})

  def init(options) do
    Process.monitor(options.engine)
    state = Map.merge(options, %{pending: nil, timer: nil})
    {:ok, arm(state, 0)}
  end

  def handle_info({:wake, reference}, %{timer: {_, reference}, pending: nil} = s) do
    token = make_ref()
    send(s.engine, {:execution_control, s.kind, self(), s.generation, token})
    {:noreply, %{s | timer: nil, pending: token}}
  end

  def handle_info({:DOWN, _, :process, engine, _}, %{engine: engine} = s),
    do: {:stop, :normal, s}

  def handle_info(_, s), do: {:noreply, s}

  def handle_cast({:ack, token, delay}, %{pending: token} = s),
    do: {:noreply, arm(%{s | pending: nil}, min(max(delay, 0), s.wake_ms))}

  def handle_cast(:wake, %{pending: nil} = s), do: {:noreply, arm(s, 0)}
  def handle_cast(_, s), do: {:noreply, s}

  defp arm(s, delay) do
    if s.timer, do: Process.cancel_timer(elem(s.timer, 0))
    reference = make_ref()
    timer = Process.send_after(self(), {:wake, reference}, delay)
    %{s | timer: {timer, reference}}
  end

  def format_status(status), do: Map.put(status, :state, :bounded_queue_demand)
end
