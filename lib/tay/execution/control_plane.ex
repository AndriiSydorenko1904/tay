defmodule Tay.Execution.ControlPlane do
  @moduledoc false

  @spec start(Supervisor.supervisor(), pid(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def start(supervisor, engine, generation, config) do
    options = %{engine: engine, generation: generation, wake_ms: config.execution_wake_ms}

    with {:ok, scheduler} <-
           start_child(supervisor, {Tay.Execution.Scheduler, options}),
         {:ok, controls} <- start_queues(supervisor, options, config.queue_limits, scheduler) do
      {:ok, controls}
    end
  end

  defp start_queues(supervisor, options, queue_limits, scheduler) do
    Enum.reduce_while(queue_limits, {:ok, %{scheduler: scheduler}}, fn {queue, _},
                                                                       {:ok, controls} ->
      kind = {:queue, queue}

      case start_child(
             supervisor,
             {Tay.Execution.Queue, Map.put(options, :kind, kind)}
           ) do
        {:ok, pid} -> {:cont, {:ok, Map.put(controls, kind, pid)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_child(supervisor, child_spec) do
    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :ignored_child}
    end
  end
end
