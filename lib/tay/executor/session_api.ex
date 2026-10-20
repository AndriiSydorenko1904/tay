defmodule Tay.Executor.SessionAPI do
  @moduledoc false

  @call_timeout 5_000

  def hello(server, connection, session),
    do: GenServer.call(server, {:hello, connection, session}, @call_timeout)

  def register_tasks(server, connection, tasks),
    do: GenServer.call(server, {:register_tasks, connection, tasks}, @call_timeout)

  def unregister_tasks(server, connection, tasks),
    do: GenServer.call(server, {:unregister_tasks, connection, tasks}, @call_timeout)

  def started(server, connection, reservation, execution),
    do: GenServer.call(server, {:started, connection, reservation, execution}, @call_timeout)

  def complete(server, connection, reservation, execution, outcome),
    do:
      GenServer.call(
        server,
        {:complete, connection, reservation, execution, outcome},
        @call_timeout
      )

  def disconnected(server, connection), do: GenServer.cast(server, {:disconnected, connection})
end
