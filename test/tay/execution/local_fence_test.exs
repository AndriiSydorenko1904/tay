defmodule Tay.Execution.LocalFenceTest do
  use ExUnit.Case, async: false
  alias Tay.Execution.LocalFence, as: Fence
  @moduletag capture_log: true

  test "lazily shares one application child and fences STORE_ID across different owners" do
    {:ok, guard} = Fence.ensure_started()
    assert {:ok, ^guard} = Fence.ensure_started()

    assert Enum.count(Supervisor.which_children(Tay.Supervisor), &match?({Fence, _, _, _}, &1)) ==
             1

    store = store_id()
    runtime = actor()
    other_engine = actor()
    guardian = self()
    {:ok, lease} = Fence.acquire(store, make_ref(), self(), guardian, runtime)
    assert Fence.guard(lease) == guard
    assert Fence.live?(lease)

    assert {:error, :local_generation_owned} =
             in_actor(other_engine, fn ->
               Fence.acquire(store, make_ref(), self(), guardian, runtime)
             end)

    assert :ok = Fence.revoke(lease)
    refute Fence.live?(lease)

    {:ok, next} =
      in_actor(other_engine, fn ->
        Fence.acquire(store, make_ref(), self(), guardian, runtime)
      end)

    assert next != lease
    assert :ok = Fence.revoke(next)
  end

  test "only registered exact task identities are live and live children cannot be forgotten" do
    runtime = actor()
    relay = actor()
    task = actor()
    unknown_task = actor()
    {:ok, lease} = Fence.acquire(store_id(), make_ref(), self(), self(), runtime)
    refute Fence.live?(lease, relay, task)
    assert :ok = Fence.register(lease, relay, task)
    assert :ok = Fence.register(lease, relay, task)
    assert Fence.live?(lease, relay, task)
    refute Fence.live?(lease, relay, unknown_task)
    refute Fence.live?(lease, runtime, task)
    assert {:error, :task_still_alive} = Fence.dead(lease, relay, task)

    {:monitors, monitors} = Process.info(Fence.guard(lease), :monitors)
    refute {:process, task} in monitors
    assert {:process, relay} in monitors
    Process.exit(task, :kill)
    assert eventually(fn -> not Process.alive?(task) end)
    assert :ok = Fence.dead(lease, relay, task)
    refute Fence.live?(lease, relay, task)

    # Retiring a registered, already-dead task removes its relay monitor. Normal
    # relay exit after its settled callback therefore does not revoke the lease.
    Process.exit(relay, :kill)
    assert Fence.live?(lease)
    assert :ok = Fence.revoke(lease)
  end

  test "untrusted callers cannot acquire for another Engine, register or retire tasks" do
    runtime = actor()
    outsider = actor()
    relay = actor()
    task = actor()
    guardian = self()
    store = store_id()

    assert {:error, :invalid_local_lease} =
             Fence.acquire(store, make_ref(), outsider, guardian, runtime)

    {:ok, lease} = Fence.acquire(store, make_ref(), self(), guardian, runtime)

    assert {:error, :invalid_task_registration} =
             in_actor(outsider, fn -> Fence.register(lease, relay, task) end)

    assert {:error, :invalid_local_lease} =
             in_actor(outsider, fn -> Fence.revoke(lease) end)

    assert :ok = in_actor(relay, fn -> Fence.register(lease, self(), task) end)
    assert :ok = Fence.revoke(lease)
    assert eventually(fn -> not Process.alive?(task) end)
  end

  for component <- [:engine, :guardian, :runtime, :relay] do
    @component component
    test "#{component} loss closes the generation and proves task death before another lease" do
      store = store_id()
      engine = actor()
      guardian = actor()
      runtime = actor()
      relay = actor()
      task = actor(trap_exit: true)
      owners = %{engine: engine, guardian: guardian, runtime: runtime, relay: relay}

      {:ok, lease} =
        in_actor(engine, fn -> Fence.acquire(store, make_ref(), self(), guardian, runtime) end)

      assert :ok = in_actor(guardian, fn -> Fence.register(lease, relay, task) end)
      Process.exit(owners[@component], :kill)
      assert eventually(fn -> not Fence.live?(lease) end)

      next_runtime = actor()

      {:ok, next} =
        eventually(fn ->
          case Fence.acquire(store, make_ref(), self(), self(), next_runtime) do
            {:ok, next} ->
              # Grant itself, not a sleeping assertion afterwards, must imply
              # that the previous callback is no longer alive.
              refute Process.alive?(task)
              {:ok, next}

            {:error, reason} when reason in [:local_generation_owned, :local_tasks_terminating] ->
              false
          end
        end)

      refute Fence.live?(lease)
      assert :ok = Fence.revoke(next)
    end
  end

  test "creator death after registration cannot orphan a task or preserve a late authorization" do
    engine = actor()
    runtime = actor()
    guardian = self()
    relay = actor()
    task = actor(trap_exit: true)
    store = store_id()

    {:ok, lease} =
      in_actor(engine, fn -> Fence.acquire(store, make_ref(), self(), guardian, runtime) end)

    # The trusted creator loses its reply to Engine after the waiting task has
    # registered. It is still in the shared ledger, not only the creator's state.
    assert :ok = in_actor(relay, fn -> Fence.register(lease, self(), task) end)
    Process.exit(engine, :kill)
    assert eventually(fn -> not Process.alive?(task) end)
    refute Fence.live?(lease, relay, task)

    {:ok, next} =
      eventually(fn ->
        case Fence.acquire(store, make_ref(), self(), self(), runtime) do
          {:ok, _} = accepted -> accepted
          {:error, :local_tasks_terminating} -> false
          {:error, :local_generation_owned} -> false
        end
      end)

    assert {:error, :invalid_local_lease} = Fence.register(lease, actor(), actor())
    assert :ok = Fence.revoke(next)
  end

  test "guard death leaves an orphan marker, never an empty replacement ownership claim" do
    runtime = actor()
    relay = actor()
    task = actor()
    store = store_id()
    {:ok, lease} = Fence.acquire(store, make_ref(), self(), self(), runtime)
    assert :ok = Fence.register(lease, relay, task)
    guard = Fence.guard(lease)
    monitor = Process.monitor(guard)
    Process.exit(guard, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^guard, :killed}
    refute Fence.live?(lease)

    assert eventually(fn ->
             case Process.whereis(Fence) do
               pid when is_pid(pid) -> pid != guard
               nil -> false
             end
           end)

    assert {:error, :local_fence_lost} =
             Fence.acquire(store, make_ref(), self(), self(), runtime)

    Process.exit(task, :kill)
    assert eventually(fn -> not Process.alive?(task) end)

    # Even a dead Engine/task observed after replacement cannot prove that its
    # lost ledger was complete. No caller-visible reset/clear bypass exists.
    assert {:error, :local_fence_lost} =
             Fence.acquire(store, make_ref(), self(), self(), runtime)

    {:ok, independent} = Fence.acquire(store_id(), make_ref(), self(), self(), runtime)
    assert :ok = Fence.revoke(independent)
  end

  test "normal application-child termination without active tasks retires its marker" do
    runtime = actor()
    store = store_id()
    {:ok, lease} = Fence.acquire(store, make_ref(), self(), self(), runtime)
    assert :ok = Supervisor.terminate_child(Tay.Supervisor, Fence)
    refute Fence.live?(lease)
    assert {:ok, _} = Fence.ensure_started()
    {:ok, next} = Fence.acquire(store, make_ref(), self(), self(), runtime)
    assert :ok = Fence.revoke(next)
  end

  defp store_id, do: :crypto.strong_rand_bytes(16)

  defp actor(options \\ []) do
    pid =
      spawn(fn ->
        Process.flag(:trap_exit, Keyword.get(options, :trap_exit, false))
        loop()
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp loop do
    receive do
      {:call, from, ref, fun} ->
        send(from, {ref, fun.()})
        loop()

      _ ->
        loop()
    end
  end

  defp in_actor(actor, fun) do
    ref = make_ref()
    send(actor, {:call, self(), ref, fun})
    assert_receive {^ref, result}, 1_000
    result
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(5)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end
end
