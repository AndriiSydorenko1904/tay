defmodule Tay.Schedule.ViaExecutor do
  @moduledoc false
  @behaviour Tay.Schedule.API

  @impl true
  def register(server, fields), do: Tay.Executor.Server.register_schedule(server, fields)

  @impl true
  def cancel(server, id), do: Tay.Executor.Server.cancel_schedule(server, id)
end
