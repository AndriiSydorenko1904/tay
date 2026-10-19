defmodule Tay.Telemetry.Poller do
  @moduledoc false
  use GenServer

  @default_period 10_000
  @default_timeout 1_000

  def child_spec(options) do
    %{
      id: Keyword.get(options, :id, __MODULE__),
      start: {__MODULE__, :start_link, [options]}
    }
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    with true <- Keyword.keyword?(options),
         engines <- Keyword.get(options, :engines, [Tay.default_name()]),
         true <- is_list(engines) and engines != [] and Enum.all?(engines, &is_atom/1),
         period <- Keyword.get(options, :period, @default_period),
         true <- is_integer(period) and period > 0,
         timeout <- Keyword.get(options, :timeout, @default_timeout),
         true <- is_integer(timeout) and timeout > 0 do
      send(self(), :poll)
      {:ok, %{engines: Enum.uniq(engines), period: period, timeout: timeout}}
    else
      _ -> {:stop, :invalid_telemetry_poller_options}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    Enum.each(state.engines, &Tay.Telemetry.emit_snapshot(&1, state.timeout))
    Process.send_after(self(), :poll, state.period)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
