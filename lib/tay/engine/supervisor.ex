defmodule Tay.Engine.Supervisor do
  @moduledoc false
  use Supervisor
  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  def start_runtime(config) do
    guardian = Process.whereis(config.name)

    with {:ok, runtime} <- Tay.Execution.Supervisor.start_link(%{}),
         :ok <- GenServer.call(guardian, {:attach_runtime, runtime}) do
      {:ok, runtime}
    end
  end

  def init(config) do
    children =
      [{Tay.Engine.Lifecycle, config}] ++
        if(config.execution, do: [runtime_spec(config)], else: []) ++ [engine_spec(config)]

    # No component may restart beneath surviving indexes. Guardian failure
    # terminates this runtime group; Engine failure leaves a closed diagnosis.
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  def start_generation(root, config) do
    with :ok <- start_execution(root, config) do
      case Supervisor.start_child(root, engine_spec(config)) do
        {:ok, _} -> :ok
        _ -> {:error, :recovery_failed}
      end
    end
  end

  defp start_execution(_root, %{execution: false}), do: :ok

  defp start_execution(root, config) do
    case Supervisor.start_child(root, runtime_spec(config)) do
      {:ok, _} -> :ok
      _ -> {:error, :runtime_start_failed}
    end
  end

  defp runtime_spec(config),
    do: %{
      id: Tay.Execution.Supervisor,
      start: {__MODULE__, :start_runtime, [config]},
      type: :supervisor,
      restart: :temporary,
      shutdown: :infinity
    }

  defp engine_spec(config),
    do: %{
      id: Tay.Engine,
      start: {Tay.Engine, :start_link, [config]},
      restart: :temporary,
      shutdown: 30_000
    }
end
