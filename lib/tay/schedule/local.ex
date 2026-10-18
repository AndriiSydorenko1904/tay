defmodule Tay.Schedule.Local do
  @moduledoc false
  @behaviour Tay.Schedule.API

  @impl true
  def register(coordinator, fields), do: Tay.Schedule.Coordinator.register(coordinator, fields)

  @impl true
  def cancel(coordinator, id), do: Tay.Schedule.Coordinator.cancel(coordinator, id)
end
