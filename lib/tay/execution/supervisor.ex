defmodule Tay.Execution.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(_options) do
    Supervisor.init(
      [
        Task.Supervisor,
        {DynamicSupervisor, strategy: :one_for_one, max_restarts: 0},
        Supervisor.child_spec(
          {DynamicSupervisor, strategy: :one_for_one, max_restarts: 10, max_seconds: 5},
          id: :controls
        )
      ],
      strategy: :one_for_all,
      max_restarts: 0
    )
  end

  def components(supervisor) do
    Map.new(Supervisor.which_children(supervisor), fn
      {Task.Supervisor, pid, _, _} -> {:tasks, pid}
      {DynamicSupervisor, pid, _, _} -> {:relays, pid}
      {:controls, pid, _, _} -> {:controls, pid}
    end)
  end

  def prepare(supervisor, options) do
    %{tasks: tasks, relays: relays} = components(supervisor)

    case DynamicSupervisor.start_child(
           relays,
           {Tay.Execution.Relay, Map.put(options, :tasks, tasks)}
         ) do
      {:ok, relay} -> Tay.Execution.Relay.identity(relay)
      {:error, _} -> {:error, :execution_start_failed}
    end
  catch
    :exit, _ -> {:error, :execution_start_failed}
  end

  # Only this short-lived trusted monitor receives arbitrary task DOWN reasons.
  # Its caller receives a constant result, never an application term. The call
  # deliberately has no successful timeout: death must be proven, not assumed.
  def stop_children(supervisor) do
    caller = self()
    ticket = make_ref()

    {helper, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            %{tasks: tasks, relays: relays} = components(supervisor)

            Enum.each(DynamicSupervisor.which_children(relays), fn {_, relay, _, _} ->
              try do
                Tay.Execution.Relay.revoke(relay)
              catch
                :exit, _ -> :ok
              end
            end)

            children = Task.Supervisor.children(tasks)
            monitors = Enum.map(children, &{Process.monitor(&1), &1})
            Enum.each(children, &Process.exit(&1, :kill))

            Enum.each(monitors, fn {ref, pid} ->
              receive do
                {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
              end
            end)

            Supervisor.stop(supervisor, :normal, :infinity)
            :ok
          catch
            _, _ -> {:error, :execution_shutdown_failed}
          end

        send(caller, {ticket, result})
      end)

    receive do
      {^ticket, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^helper, _} ->
        {:error, :execution_shutdown_failed}
    end
  end
end
