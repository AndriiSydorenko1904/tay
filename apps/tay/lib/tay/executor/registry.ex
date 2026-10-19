defmodule Tay.Executor.Registry do
  @moduledoc false

  alias Tay.Executor.Protocol

  def valid_session?(%{mode: mode, runtime_id: id, capacity: capacity}) do
    mode in ["client", "embedded", "worker"] and Protocol.identifier?(id) and
      is_integer(capacity) and capacity in 0..65_535 and
      (mode == "client" or capacity > 0) and (mode != "client" or capacity == 0)
  end

  def valid_session?(_), do: false

  def executor(connections, connection) do
    case Map.get(connections, connection) do
      %{mode: mode} = entry when mode in ["embedded", "worker"] -> {:ok, entry}
      %{mode: "client"} -> {:error, "client_cannot_execute"}
      nil -> {:error, "connection_closed"}
      _ -> {:error, "hello_required"}
    end
  end

  def valid_tasks?(tasks, maximum) do
    is_list(tasks) and length(tasks) <= maximum and Enum.all?(tasks, &Protocol.task_key?/1) and
      length(tasks) == length(Enum.uniq(tasks))
  end

  def capabilities(connections) do
    connections
    |> Enum.filter(fn {_connection, entry} -> available?(entry) end)
    |> Enum.flat_map(fn {_connection, entry} -> MapSet.to_list(entry.tasks) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def choose(connections, task, queue) do
    if Protocol.task_key?(task) do
      connections
      |> Enum.filter(fn {_connection, entry} ->
        available?(entry) and MapSet.member?(entry.tasks, task) and
          (queue == :all or Map.get(entry, :queue, :all) in [:all, queue])
      end)
      |> Enum.min_by(
        fn {connection, entry} ->
          {MapSet.size(entry.reservations), entry.runtime_id, connection}
        end,
        fn -> nil end
      )
      |> case do
        nil -> nil
        {connection, _} -> connection
      end
    end
  end

  defp available?(entry),
    do: entry.mode in ["embedded", "worker"] and MapSet.size(entry.reservations) < entry.capacity
end
