defmodule Tay.Execution.Executor do
  @moduledoc false
  alias Tay.Execution.Outcome

  def start(tasks, relay, options, ticket) do
    Task.Supervisor.start_child(
      tasks,
      fn -> waiting(relay, options, ticket) end,
      restart: :temporary,
      shutdown: :brutal_kill
    )
  end

  defp waiting(relay, options, ticket) do
    relay_monitor = Process.monitor(relay)
    engine_monitor = Process.monitor(options.engine)
    guardian_monitor = Process.monitor(options.guardian)

    receive do
      {:tay_execution_release, ^relay, ^ticket, generation, execution, job, deadline}
      when generation == options.generation ->
        enter(relay, options, ticket, execution, job, deadline, [
          relay_monitor,
          engine_monitor,
          guardian_monitor
        ])

      {:DOWN, ref, :process, _, _}
      when ref in [relay_monitor, engine_monitor, guardian_monitor] ->
        :ok
    end
  end

  defp enter(relay, options, ticket, execution, job, deadline, monitors) do
    if live?(options, relay) do
      enter_live(relay, options, ticket, execution, job, deadline, monitors)
    else
      send(relay, {:tay_execution_invalidated, self(), ticket})
    end
  end

  defp enter_live(relay, options, ticket, execution, job, deadline, monitors) do
    [relay_monitor, engine_monitor, guardian_monitor] = monitors
    remaining = deadline - options.clock.monotonic_ms()
    wall = options.clock.wall_ms()
    due = Map.get(options, :eligible_at, wall)

    cond do
      remaining <= 0 ->
        :ok

      wall < due ->
        # A clock step between Engine's final check and callback entry cannot
        # cause an early callback. The original release deadline still applies;
        # this wait never invents an infrastructure interruption or resets time.
        receive do
          {:DOWN, ref, :process, _, _}
          when ref in [relay_monitor, engine_monitor, guardian_monitor] ->
            :ok
        after
          min(1_000, min(remaining, due - wall)) ->
            enter(relay, options, ticket, execution, job, deadline, monitors)
        end

      true ->
        # Normalize inside the task, before Task's crash reporter or the relay
        # can receive a returned/raised/thrown/exited application term.
        outcome =
          try do
            Outcome.returned(options.worker.perform(job))
          catch
            kind, _term -> Outcome.caught(kind)
          end

        send(relay, {:tay_execution_result, self(), ticket, execution, outcome})
    end
  end

  defp live?(options, relay) do
    Process.alive?(options.engine) and
      GenServer.call(
        options.guardian,
        {:execution_live, options.generation, options.engine, relay, self()},
        5_000
      ) == :ok
  catch
    :exit, _ -> false
  end
end
