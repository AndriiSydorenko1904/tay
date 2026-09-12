defmodule Tay.Execution.Relay do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Tay.Execution.Executor
  @test Mix.env() == :test

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def identity(relay), do: GenServer.call(relay, :identity)

  def release(relay, ticket, execution, job),
    do: GenServer.call(relay, {:release, ticket, execution, job})

  def settled(relay, ticket), do: GenServer.call(relay, {:settled, ticket})
  def terminate_task(relay, ticket), do: GenServer.call(relay, {:terminate_task, ticket})
  def revoke(relay), do: GenServer.call(relay, :revoke)

  @impl true
  def init(options) do
    ticket = make_ref()

    with {:ok, task} <- Executor.start(options.tasks, self(), options, ticket),
         :ok <- register(options, task) do
      {:ok,
       %{
         options: options,
         ticket: ticket,
         task: task,
         task_monitor: Process.monitor(task),
         owner_monitors:
           Enum.map([options.engine, options.guardian, options.tasks], &Process.monitor/1),
         execution: nil,
         deadline: nil,
         timer: nil,
         chosen: nil,
         dead: false,
         settled: false
       }}
    else
      _ -> {:stop, :execution_start_failed}
    end
  end

  defp register(options, task) do
    try do
      case GenServer.call(
             options.guardian,
             {:execution_child, options.generation, self(), task},
             5_000
           ) do
        :ok ->
          :ok

        _ ->
          Process.exit(task, :kill)
          {:error, :generation_revoked}
      end
    catch
      :exit, _ ->
        Process.exit(task, :kill)
        {:error, :generation_revoked}
    end
  end

  @impl true
  def handle_call(:identity, _, s),
    do: {:reply, {:ok, %{relay: self(), task: s.task, ticket: s.ticket}}, s}

  def handle_call(:revoke, _, s) do
    cancel_timer(s)
    if not s.dead, do: Process.exit(s.task, :kill)
    s = %{s | settled: true, chosen: :infrastructure_lost}
    if s.dead, do: {:stop, :normal, :ok, s}, else: {:reply, :ok, s}
  end

  def handle_call({:release, ticket, execution, job}, {engine, _}, s)
      when ticket == s.ticket and engine == s.options.engine and is_integer(execution) and
             execution > 0 do
    cond do
      s.execution != nil or s.settled ->
        {:reply, {:error, :already_released}, s}

      s.dead ->
        {:reply, {:error, :task_dead}, s}

      not live?(s) ->
        {:reply, {:error, :generation_revoked}, s}

      true ->
        deadline = s.options.clock.monotonic_ms() + s.options.timeout_ms
        timer = Process.send_after(self(), {:timeout, ticket}, s.options.timeout_ms)

        send(
          s.task,
          {:tay_execution_release, self(), ticket, s.options.generation, execution, job, deadline}
        )

        {:reply, :ok, %{s | execution: execution, deadline: deadline, timer: timer}}
    end
  end

  def handle_call({action, ticket}, {engine, _}, s)
      when action in [:settled, :terminate_task] and ticket == s.ticket and
             engine == s.options.engine do
    cancel_timer(s)
    if not s.dead, do: request_termination(s)
    s = %{s | settled: true, chosen: s.chosen || :fenced}
    if s.dead, do: {:stop, :normal, :ok, s}, else: {:reply, :ok, s}
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_execution_request}, s}

  @impl true
  def handle_info({:tay_execution_invalidated, task, ticket}, %{task: task, ticket: ticket} = s),
    do: {:stop, :generation_revoked, %{s | chosen: :infrastructure_lost}}

  def handle_info({:tay_execution_result, task, ticket, execution, outcome}, s)
      when task == s.task and ticket == s.ticket and execution == s.execution and
             not is_nil(execution) do
    if s.chosen == nil and valid_outcome?(outcome) do
      outcome = if expired?(s), do: :timeout, else: outcome
      {:noreply, choose(s, outcome)}
    else
      {:noreply, s}
    end
  end

  def handle_info({:timeout, ticket}, %{ticket: ticket, chosen: nil, execution: execution} = s)
      when not is_nil(execution) do
    if expired?(s) do
      {:noreply, choose(s, :timeout)}
    else
      timer =
        Process.send_after(
          self(),
          {:timeout, ticket},
          max(1, s.deadline - s.options.clock.monotonic_ms())
        )

      {:noreply, %{s | timer: timer}}
    end
  end

  def handle_info({:DOWN, ref, :process, task, _reason}, %{task_monitor: ref, task: task} = s) do
    s = %{s | dead: true}
    observed = if s.execution != nil and expired?(s), do: :timeout, else: {:failure, 4}

    if s.execution != nil and s.chosen == nil and not infrastructure_live?(s) do
      {:stop, :generation_revoked, %{s | chosen: :infrastructure_lost}}
    else
      confirmed_down(s, observed)
    end
  end

  def handle_info({:DOWN, ref, :process, _, _reason}, s) do
    if ref in s.owner_monitors do
      cancel_timer(s)
      if not s.dead, do: Process.exit(s.task, :kill)
      s = %{s | settled: true, chosen: :infrastructure_lost}
      if s.dead, do: {:stop, :normal, s}, else: {:noreply, s}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp confirmed_down(s, observed) do
    # Guardian must remove the exact task/relay from the VM-local fence before
    # this relay can exit normally. An async notification races its monitor DOWN
    # and can incorrectly revoke an otherwise successful generation.
    case confirm_death(s) do
      :ok ->
        s = if s.execution != nil and s.chosen == nil, do: choose(s, observed), else: s
        notify(s, :dead)
        if s.settled, do: {:stop, :normal, s}, else: {:noreply, s}

      _ ->
        {:stop, :generation_revoked, %{s | chosen: :infrastructure_lost}}
    end
  end

  defp choose(s, outcome) do
    cancel_timer(s)
    notify(s, {:outcome, outcome})
    %{s | chosen: outcome, timer: nil}
  end

  defp notify(s, event),
    do:
      send(
        s.options.engine,
        {:tay_execution, self(), s.ticket, s.options.generation, s.execution, event}
      )

  defp live?(s) do
    Process.alive?(s.options.engine) and
      GenServer.call(
        s.options.guardian,
        {:execution_live, s.options.generation, s.options.engine, self(), s.task},
        5_000
      ) == :ok
  catch
    :exit, _ -> false
  end

  defp confirm_death(s) do
    GenServer.call(
      s.options.guardian,
      {:execution_child_dead, s.options.generation, self(), s.task},
      5_000
    )
  catch
    :exit, _ -> {:error, :death_confirmation_failed}
  end

  defp infrastructure_live?(s) do
    # Task.Supervisor can kill a child during shutdown before its own DOWN is
    # delivered here. A bounded roundtrip cannot succeed while that supervisor
    # is terminating; its child death must not become a worker failure.
    Process.alive?(s.options.engine) and Process.alive?(s.options.guardian) and
      count_shape?(GenServer.call(s.options.tasks, :count_children, 5_000)) and
      GenServer.call(
        s.options.guardian,
        {:execution_owner_live, s.options.generation, s.options.engine},
        5_000
      ) == :ok
  catch
    :exit, _ -> false
  end

  defp count_shape?([_, _, _, _] = counts) do
    Keyword.keyword?(counts) and
      Enum.sort(Keyword.keys(counts)) == [:active, :specs, :supervisors, :workers] and
      Enum.all?(counts, fn {_, count} -> is_integer(count) and count >= 0 end)
  end

  defp count_shape?(_), do: false

  defp expired?(s), do: s.options.clock.monotonic_ms() >= s.deadline
  defp valid_outcome?(:success), do: true
  defp valid_outcome?({:failure, code}) when code in [1, 2, 3, 4, 6], do: true
  defp valid_outcome?(_), do: false
  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(s), do: Process.cancel_timer(s.timer)

  defp request_termination(s) do
    if @test and is_function(Map.get(s.options, :test_terminate), 1),
      do: s.options.test_terminate.(s.task),
      else: Process.exit(s.task, :kill)
  end

  @impl true
  def terminate(_, s) do
    if not s.dead, do: Process.exit(s.task, :kill)
    :ok
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_execution)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :execution_failed)
end
