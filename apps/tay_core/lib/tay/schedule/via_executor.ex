defmodule Tay.Schedule.ViaExecutor do
  @moduledoc false
  @behaviour Tay.Schedule.API

  @impl true
  def register(server, fields) do
    with {:ok, coordinator} <- GenServer.call(server, :schedule_coordinator, 5_000),
         do: Tay.Schedule.Local.register(coordinator, fields)
  end

  @impl true
  def cancel(server, id) do
    with {:ok, coordinator} <- GenServer.call(server, :schedule_coordinator, 5_000),
         do: Tay.Schedule.Local.cancel(coordinator, id)
  end
end
