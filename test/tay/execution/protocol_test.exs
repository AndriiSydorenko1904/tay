defmodule Tay.Execution.ProtocolGuardian do
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def init(options), do: {:ok, Map.merge(options, %{children: %{}, live: true})}

  def handle_call({:execution_child, generation, relay, task}, _, %{generation: generation} = s) do
    ref = Process.monitor(relay)
    {:reply, :ok, %{s | children: Map.put(s.children, ref, {relay, task})}}
  end

  def handle_call({:execution_live, generation, engine, relay, task}, _, s),
    do:
      {:reply,
       if(
         s.live and s.generation == generation and s.engine == engine and
           Enum.any?(s.children, fn {_, pair} -> pair == {relay, task} end),
         do: :ok,
         else: :revoked
       ), s}

  def handle_call(:revoke, _, s), do: {:reply, :ok, %{s | live: false}}

  def handle_call({:execution_owner_live, generation, engine}, _, s),
    do:
      {:reply,
       if(s.live and s.generation == generation and s.engine == engine and Process.alive?(engine),
         do: :ok,
         else: :revoked
       ), s}

  def handle_call({:hold_death, observer}, _, s),
    do: {:reply, :ok, Map.put(s, :death_observer, observer)}

  def handle_call(
        {:execution_child_dead, generation, relay, task},
        {relay, _},
        %{generation: generation} = s
      ) do
    if observer = Map.get(s, :death_observer) do
      send(observer, {:confirming_death, self()})

      receive do
        :confirm_death -> :ok
      end
    end

    if not Process.alive?(task) do
      {ref, _} = Enum.find(s.children, fn {_, pair} -> pair == {relay, task} end)
      Process.demonitor(ref, [:flush])
      {:reply, :ok, %{s | children: Map.delete(s.children, ref)}}
    else
      {:reply, {:error, :task_alive}, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.get(s.children, ref) do
      {_, task} -> Process.exit(task, :kill)
      nil -> :ok
    end

    {:noreply, %{s | children: Map.delete(s.children, ref)}}
  end

  def handle_info(_, s), do: {:noreply, s}
end

defmodule Tay.Execution.ProtocolWorker do
  def perform(%{parent: parent, action: action}) do
    send(parent, {:callback_entered, self()})

    case action do
      {:return, value} ->
        value

      {:raise, value} ->
        raise value

      {:throw, value} ->
        throw(value)

      {:exit, value} ->
        exit(value)

      {:self_exit, value} ->
        Process.exit(self(), value)

      :wait ->
        receive do
          :return -> :ok
        end

      :trap ->
        Process.flag(:trap_exit, true)
        send(parent, {:trapping, self()})

        receive do
          :return -> :ok
        end
    end
  end
end

defmodule Tay.Execution.ProtocolClock do
  def wall_ms, do: :atomics.get(:persistent_term.get(__MODULE__), 1)
  def monotonic_ms, do: :atomics.get(:persistent_term.get(__MODULE__), 2)
end

defmodule Tay.Execution.ProtocolTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  import ExUnit.CaptureLog
  alias Tay.Execution.{Relay, Supervisor}

  setup do
    generation = make_ref()

    guardian =
      start_supervised!(
        {Tay.Execution.ProtocolGuardian, %{generation: generation, engine: self()}}
      )

    runtime = start_supervised!({Supervisor, %{}})

    options = %{
      guardian: guardian,
      engine: self(),
      generation: generation,
      worker: Tay.Execution.ProtocolWorker,
      timeout_ms: 5_000,
      clock: Tay.Execution.Clock
    }

    %{runtime: runtime, guardian: guardian, options: options}
  end

  defp prepare(context, extra \\ %{}),
    do: Supervisor.prepare(context.runtime, Map.merge(context.options, extra))

  defp job(action), do: %{parent: self(), action: action}

  test "supervised task waits past its timeout until exact post-commit release", c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c, %{timeout_ms: 30})
    assert task in Task.Supervisor.children(Supervisor.components(c.runtime).tasks)
    refute_receive {:callback_entered, _}, 50
    refute_receive {:tay_execution, _, _, _, _, _}, 0
    assert :ok = Relay.release(relay, ticket, 42, job({:return, :ok}))
    assert_receive {:callback_entered, ^task}
    assert_receive {:tay_execution, ^relay, ^ticket, _, 42, {:outcome, :success}}
    assert_receive {:tay_execution, ^relay, ^ticket, _, 42, :dead}
    assert :ok = Relay.settled(relay, ticket)
  end

  test "wrong owner, ticket and revoked generation cannot enter user code", c do
    {:ok, %{relay: relay, ticket: ticket}} = prepare(c)
    assert {:error, :invalid_execution_request} = Relay.release(relay, make_ref(), 1, job(:wait))
    owner = self()
    spawn(fn -> send(owner, {:foreign, Relay.release(relay, ticket, 1, job(:wait))}) end)
    assert_receive {:foreign, {:error, :invalid_execution_request}}
    assert :ok = GenServer.call(c.guardian, :revoke)
    assert {:error, :generation_revoked} = Relay.release(relay, ticket, 1, job(:wait))
    refute_receive {:callback_entered, _}
    assert :ok = Relay.terminate_task(relay, ticket)
    assert_receive {:tay_execution, ^relay, ^ticket, _, nil, :dead}
  end

  test "all arbitrary outcomes are normalized without default logging", c do
    secret = "private-marker-" <> String.duplicate("x", 500_000)

    captured =
      capture_log(fn ->
        for {action, expected} <- [
              {{:return, :ok}, :success},
              {{:return, {:ok, secret}}, :success},
              {{:return, {:error, secret}}, {:failure, 1}},
              {{:raise, secret}, {:failure, 2}},
              {{:throw, secret}, {:failure, 3}},
              {{:exit, secret}, {:failure, 4}},
              {{:self_exit, secret}, {:failure, 4}},
              {{:return, secret}, {:failure, 6}}
            ] do
          {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
          :ok = Relay.release(relay, ticket, 7, job(action))
          assert_receive {:callback_entered, ^task}
          assert_receive {:tay_execution, ^relay, ^ticket, _, 7, {:outcome, ^expected}} = message
          assert :erlang.external_size(message) < 256
          assert_receive {:tay_execution, ^relay, ^ticket, _, 7, :dead}
          :ok = Relay.settled(relay, ticket)
        end
      end)

    refute captured =~ "private-marker"
    refute captured =~ "terminating"
  end

  test "timeout is chosen once, does not kill before durable settlement, and rejects late success",
       c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c, %{timeout_ms: 30})
    :ok = Relay.release(relay, ticket, 9, job(:wait))
    assert_receive {:callback_entered, ^task}
    assert_receive {:tay_execution, ^relay, ^ticket, _, 9, {:outcome, :timeout}}, 1_000
    assert Process.alive?(task)
    send(task, :return)
    assert_receive {:tay_execution, ^relay, ^ticket, _, 9, :dead}
    refute_receive {:tay_execution, ^relay, ^ticket, _, 9, {:outcome, _}}
    :ok = Relay.settled(relay, ticket)
  end

  test "durable cancellation or timeout fence kills even a task trapping exits", c do
    for action <- [:terminate_task, :settled] do
      {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
      :ok = Relay.release(relay, ticket, 12, job(:trap))
      assert_receive {:callback_entered, ^task}
      assert_receive {:trapping, ^task}
      assert :ok = apply(Relay, action, [relay, ticket])
      assert_receive {:tay_execution, ^relay, ^ticket, _, 12, :dead}
      refute Process.alive?(task)
      refute_receive {:tay_execution, ^relay, ^ticket, _, 12, {:outcome, _}}
    end
  end

  test "waiting task death produces no attempt outcome and forbids release", c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
    Process.exit(task, :kill)
    assert_receive {:tay_execution, ^relay, ^ticket, _, nil, :dead}
    refute_receive {:tay_execution, ^relay, ^ticket, _, _, {:outcome, _}}
    assert {:error, :task_dead} = Relay.release(relay, ticket, 19, job(:wait))
    assert :ok = Relay.terminate_task(relay, ticket)
  end

  test "relay cannot publish death or exit normally before guardian acknowledges fence removal",
       c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
    :ok = Relay.release(relay, ticket, 20, job(:wait))
    assert_receive {:callback_entered, ^task}
    :ok = GenServer.call(c.guardian, {:hold_death, self()})
    monitor = Process.monitor(relay)
    Process.exit(task, :kill)
    assert_receive {:confirming_death, guardian}

    reply = make_ref()
    send(relay, {:"$gen_call", {self(), reply}, {:settled, ticket}})
    refute_receive {:tay_execution, ^relay, ^ticket, _, 20, :dead}, 20
    refute_receive {:DOWN, ^monitor, :process, ^relay, _}, 0
    refute_receive {^reply, _}, 0

    send(guardian, :confirm_death)
    assert_receive {:tay_execution, ^relay, ^ticket, _, 20, {:outcome, {:failure, 4}}}
    assert_receive {:tay_execution, ^relay, ^ticket, _, 20, :dead}
    assert_receive {^reply, :ok}
    assert_receive {:DOWN, ^monitor, :process, ^relay, :normal}
    assert :sys.get_state(guardian).children == %{}
  end

  test "relay loss kills the registered callback through guardian identity", c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
    :ok = Relay.release(relay, ticket, 2, job(:trap))
    assert_receive {:callback_entered, ^task}
    assert_receive {:trapping, ^task}
    monitor = Process.monitor(task)
    Process.exit(relay, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
  end

  test "guardian loss kills a running callback even if it traps exits", c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
    :ok = Relay.release(relay, ticket, 2, job(:trap))
    assert_receive {:callback_entered, ^task}
    assert_receive {:trapping, ^task}
    monitor = Process.monitor(task)
    relay_monitor = Process.monitor(relay)
    Process.exit(c.guardian, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay, :generation_revoked}
    refute_receive {:tay_execution, ^relay, ^ticket, _, 2, {:outcome, _}}
  end

  test "Engine loss kills the callback and never reports a worker failure", c do
    parent = self()

    engine =
      spawn(fn ->
        receive do
          {:release, relay, ticket, job} ->
            send(parent, {:released, Relay.release(relay, ticket, 14, job)})

            receive do
              :stop -> :ok
            end
        end
      end)

    guardian =
      start_supervised!(%{
        id: :other_guardian,
        start:
          {Tay.Execution.ProtocolGuardian, :start_link,
           [%{generation: c.options.generation, engine: engine}]}
      })

    {:ok, %{relay: relay, task: task, ticket: ticket}} =
      prepare(c, %{engine: engine, guardian: guardian})

    send(engine, {:release, relay, ticket, job(:trap)})
    assert_receive {:released, :ok}
    assert_receive {:callback_entered, ^task}
    assert_receive {:trapping, ^task}
    monitor = Process.monitor(task)
    Process.exit(engine, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
  end

  test "runtime supervisor owner loss cannot leave exit-trapping callbacks alive", c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
    :ok = Relay.release(relay, ticket, 15, job(:trap))
    assert_receive {:callback_entered, ^task}
    assert_receive {:trapping, ^task}
    monitor = Process.monitor(task)
    Process.exit(c.runtime, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
  end

  test "task-supervisor loss cannot leave exit-trapping callbacks alive", c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
    :ok = Relay.release(relay, ticket, 16, job(:trap))
    assert_receive {:callback_entered, ^task}
    assert_receive {:trapping, ^task}
    monitor = Process.monitor(task)
    Process.exit(Supervisor.components(c.runtime).tasks, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
  end

  test "child DOWN from task-supervisor shutdown is infrastructure loss, never worker failure",
       c do
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok, relay} =
      DynamicSupervisor.start_child(
        Supervisor.components(c.runtime).relays,
        {Relay, Map.put(c.options, :tasks, tasks)}
      )

    {:ok, %{task: task, ticket: ticket}} = Relay.identity(relay)
    :ok = Relay.release(relay, ticket, 30, job(:trap))
    assert_receive {:callback_entered, ^task}
    assert_receive {:trapping, ^task}
    monitor = Process.monitor(task)

    # Suspend the relay until Task.Supervisor's child has died. The queued child
    # DOWN is ahead of supervisor DOWN, exactly the dangerous ordering.
    :ok = :sys.suspend(relay)
    caller = self()

    spawn(fn ->
      try do
        GenServer.stop(tasks, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      send(caller, :task_supervisor_stopped)
    end)

    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    :ok = :sys.resume(relay)
    assert_receive :task_supervisor_stopped
    refute_receive {:tay_execution, ^relay, ^ticket, _, 30, {:outcome, _}}, 100
  end

  test "runtime shutdown confirms task death without exposing raw reasons", c do
    {:ok, %{relay: relay, task: task, ticket: ticket}} = prepare(c)
    :ok = Relay.release(relay, ticket, 2, job(:trap))
    assert_receive {:callback_entered, ^task}
    assert_receive {:trapping, ^task}
    assert :ok = Supervisor.stop_children(c.runtime)
    refute Process.alive?(task)
    refute Process.alive?(relay)
    refute Process.alive?(c.runtime)
    refute_receive {:tay_execution, ^relay, ^ticket, _, 2, {:outcome, _}}
  end

  test "final wall-clock recheck prevents early entry and retains the release deadline", c do
    clock = :atomics.new(2, signed: true)
    :persistent_term.put(Tay.Execution.ProtocolClock, clock)
    on_exit(fn -> :persistent_term.erase(Tay.Execution.ProtocolClock) end)

    {:ok, %{relay: relay, task: task, ticket: ticket}} =
      prepare(c, %{clock: Tay.Execution.ProtocolClock, eligible_at: 100, timeout_ms: 5_000})

    :ok = Relay.release(relay, ticket, 11, job({:return, :ok}))
    refute_receive {:callback_entered, _}, 30
    # A further backwards step remains ineligible; a forward step makes the
    # same authorized task eligible without a second start or new deadline.
    :atomics.put(clock, 1, -100)
    refute_receive {:callback_entered, _}, 100
    :atomics.put(clock, 1, 100)
    assert_receive {:callback_entered, ^task}, 1_000
    assert_receive {:tay_execution, ^relay, ^ticket, _, 11, {:outcome, :success}}
    assert_receive {:tay_execution, ^relay, ^ticket, _, 11, :dead}
    :ok = Relay.settled(relay, ticket)

    :atomics.put(clock, 1, 0)

    {:ok, %{relay: relay, ticket: ticket}} =
      prepare(c, %{clock: Tay.Execution.ProtocolClock, eligible_at: 1_000, timeout_ms: 100})

    :ok = Relay.release(relay, ticket, 12, job({:return, :ok}))
    :atomics.put(clock, 2, 100)
    send(relay, {:timeout, ticket})
    assert_receive {:tay_execution, ^relay, ^ticket, _, 12, {:outcome, :timeout}}
    refute_receive {:callback_entered, _}, 0
    :ok = Relay.settled(relay, ticket)
    assert_receive {:tay_execution, ^relay, ^ticket, _, 12, :dead}
  end
end
