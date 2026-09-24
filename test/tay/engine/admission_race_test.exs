defmodule Tay.Engine.AdmissionRaceTest do
  use ExUnit.Case, async: false

  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers, RecoveryHelpers}

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, options) do
    assert {:ok, root} = EngineHelpers.start(path, @name, options)
    Process.unlink(root)
    on_exit(fn -> EngineHelpers.stop(root) end)
    root
  end

  defp intent(value) do
    assert {:ok, intent} = EngineWorker.new(%{"value" => inspect(value)})

    intent
  end

  test "a successful reply observes its permit already reusable", %{path: path} do
    parent = self()
    calls = :atomics.new(1, [])

    hook = fn point ->
      if point == :post_reply and :atomics.add_get(calls, 1, 1) == 1 do
        send(parent, {:post_reply, self()})

        receive do
          :continue -> :ok
        end
      end
    end

    start(path, client_slots: 1, test_hook: hook)
    first = Task.async(fn -> Tay.insert(intent(:first), name: @name) end)

    assert_receive {:post_reply, engine}
    assert {:ok, _} = Task.await(first)

    assert Tay.status(name: @name).client_slot_states == %{
             free: 1,
             claimed: 0,
             reserved: 0,
             submitted: 0
           }

    second = Task.async(fn -> Tay.insert(intent(:second), name: @name) end)

    assert EngineHelpers.eventually(fn ->
             Tay.status(name: @name).client_slot_states.submitted == 1
           end)

    send(engine, :continue)
    assert {:ok, _} = Task.await(second)
    assert EngineHelpers.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
  end

  test "one fast sequential caller cannot accumulate submitted permits", %{path: path} do
    start(path, client_slots: 2)

    for index <- 1..100 do
      assert {:ok, _} = Tay.insert(intent(index), name: @name)
    end

    assert Tay.status(name: @name).client_slot_states == %{
             free: 2,
             claimed: 0,
             reserved: 0,
             submitted: 0
           }
  end

  test "multiple fast sequential callers do not exhaust stale submitted permits", %{path: path} do
    start(path, client_slots: 4)

    callers =
      for producer <- 1..4 do
        Task.async(fn ->
          for index <- 1..50 do
            assert {:ok, _} = Tay.insert(intent("#{producer}:#{index}"), name: @name)
          end
        end)
      end

    Enum.each(callers, &Task.await(&1, 15_000))
    assert Tay.status(name: @name).client_slots_used == 0
    assert Tay.status(name: @name).client_slot_states.free == 4
  end

  test "genuinely concurrent submitted commands still receive bounded backpressure", %{path: path} do
    parent = self()
    calls = :atomics.new(1, [])

    hook = fn point ->
      if point == :pre_reply and :atomics.add_get(calls, 1, 1) == 1 do
        send(parent, {:pre_reply, self()})

        receive do
          :continue -> :ok
        end
      end
    end

    start(path, client_slots: 2, test_hook: hook)
    first = Task.async(fn -> Tay.insert(intent(:first), name: @name) end)
    assert_receive {:pre_reply, engine}
    second = Task.async(fn -> Tay.insert(intent(:second), name: @name) end)

    assert EngineHelpers.eventually(fn ->
             Tay.status(name: @name).client_slot_states.submitted == 2
           end)

    assert {:error, %Tay.Error{kind: :capacity, reason: :client_slots}} =
             Tay.get_job(Tay.JobID.new(), name: @name)

    send(engine, :continue)
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = Task.await(second)
    assert EngineHelpers.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
  end

  test "a normal command error is replied only after releasing its permit", %{path: path} do
    start(path, client_slots: 1)

    assert {:error, :not_found} = Tay.get_job(Tay.JobID.new(), name: @name)
    assert Tay.status(name: @name).client_slots_used == 0
    assert Tay.status(name: @name).client_slot_states.free == 1
  end
end
