defmodule Tay.Engine.SharedMemoryTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers, RecoveryHelpers}
  alias Tay.State.Memory
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "schedules and jobs share bytes without per-feature quotas; control works at capacity", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.start(path, @name, max_state_bytes: 150_000)

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    schedule = schedule("dominant", 20_000)
    assert {:ok, _} = Tay.register_schedule(schedule, name: @name)

    for n <- 1..3 do
      assert {:ok, _} = Tay.register_schedule(schedule("extra-#{n}", 2_048), name: @name)
    end

    status = Tay.status(name: @name)
    assert status.auxiliary_state_bytes_charged > 120_000
    assert status.state_bytes_charged == status.auxiliary_state_bytes_charged

    assert {:error, %{kind: :capacity}} =
             Tay.insert(EngineWorker, %{"blob" => String.duplicate("x", 70_000)}, name: @name)

    assert {:ok, meta} = Tay.Engine.Admission.metadata(@name)
    remaining = meta.memory.limit - Memory.used(meta.memory)
    assert :ok = Memory.reserve(meta.memory, remaining)

    try do
      assert {:ok, %{cancelled_at: at}} = Tay.cancel_schedule(schedule.id, name: @name)
      assert is_integer(at)
      assert Memory.used(meta.memory) == meta.memory.limit
    after
      Memory.release(meta.memory, remaining)
    end

    assert Tay.status(name: @name).state == :ready
  end

  test "restart refuses an insufficient shared budget without discarding schedules", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)
    assert {:ok, _} = Tay.register_schedule(schedule("retained", 16_384), name: @name)
    required = Tay.status(name: @name).state_bytes_charged
    EngineHelpers.stop(root)
    assert {:error, error} = EngineHelpers.start(path, @name, max_state_bytes: 1_000)
    assert inspect(error) =~ "max_state_bytes"
    assert inspect(error) =~ Integer.to_string(required)
    {:ok, root} = EngineHelpers.restart(path, @name)

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert {:ok, %{id: "retained"}} = Tay.get_schedule("retained", name: @name)
    assert Tay.status(name: @name).state_bytes_charged == required
  end

  test "both schedule and result reducers enforce the common budget" do
    seed = Tay.Storage.V2.Reducer.candidate(%{max_bytes: 0})
    item = schedule("bounded", 65_536)

    checkpoint = %Tay.Event{
      record_type: 13,
      payload_schema_version: 2,
      data: %{
        "at" => 1_000,
        "expected_revision" => 0,
        "revision" => 1,
        "schedule_id" => item.id,
        "definition" => item.definition,
        "registered_at" => 1_000,
        "next_at" => item.next_at,
        "last_at" => nil,
        "cancelled_at" => nil,
        "active_job_id" => nil,
        "active_job_ids" => [],
        "membership_complete" => true
      }
    }

    assert {:error, {:resource_limit, :retained_bytes}} =
             Tay.State.Auxiliary.reduce(checkpoint, %{sequence: 1}, seed)

    id = <<1::128>>

    event = %Tay.Event{
      record_type: 10,
      payload_schema_version: 2,
      data: %{
        "at" => 1_000,
        "expected_revision" => 1,
        "job_id" => id,
        "result" => %{"blob" => String.duplicate("x", 65_536)}
      }
    }

    seed = %{seed | jobs: %{id => %{state: :completed, revision: 1}}}

    assert {:error, {:resource_limit, :retained_bytes}} =
             Tay.State.Auxiliary.reduce(event, %{sequence: 2}, seed)
  end

  test "paged schedule reads are ordered and bounded and direct lookup/cancel ignore other pages",
       %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    for n <- 1..107 do
      id = "schedule-" <> String.pad_leading(Integer.to_string(n), 3, "0")
      assert {:ok, _} = Tay.register_schedule(schedule(id, 0), name: @name)
    end

    assert {:ok, first} = Tay.schedule_page(name: @name)
    assert length(first.schedules) == 50
    assert first.next_cursor == "schedule-050"
    assert {:ok, second} = Tay.schedule_page(name: @name, cursor: first.next_cursor)
    assert length(second.schedules) == 50
    assert second.next_cursor == "schedule-100"
    assert {:ok, last} = Tay.schedule_page(name: @name, cursor: second.next_cursor)
    assert length(last.schedules) == 7
    assert is_nil(last.next_cursor)
    assert {:ok, all} = Tay.schedules(name: @name)
    assert length(all) == 107
    assert {:ok, %{id: "schedule-107"}} = Tay.get_schedule("schedule-107", name: @name)
    assert {:ok, _} = Tay.cancel_schedule("schedule-107", name: @name)
    assert {:error, :not_found} = Tay.get_schedule("missing", name: @name)

    for limit <- [0, 101, "1"] do
      assert {:error, :invalid_schedule_page} = Tay.schedule_page(name: @name, limit: limit)
    end
  end

  test "schedule admission is bounded and a lost caller cannot release submitted payloads", %{
    path: path
  } do
    owner = self()
    {:ok, gate} = Agent.start_link(fn -> true end)

    hook = fn
      :pre_reply ->
        if Agent.get_and_update(gate, fn blocked -> {blocked, false} end) do
          send(owner, {:blocked_commit, self()})

          receive do
            :resume -> :ok
          end
        end

      _ ->
        :ok
    end

    {:ok, root} = EngineHelpers.start(path, @name, client_slots: 1, test_hook: hook)

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, coordinator} =
      Tay.Schedule.Coordinator.start_link(%{core: {Tay.Core.Local, @name}, schedules: %{}})

    on_exit(fn -> if Process.alive?(coordinator), do: GenServer.stop(coordinator) end)

    fields = %{
      "declaration_id" => "queued",
      "task" => "worker.v1",
      "every" => %{"hours" => 1},
      "delay" => 60
    }

    caller = spawn(fn -> Tay.Schedule.Coordinator.register(coordinator, fields) end)
    assert_receive {:blocked_commit, engine}, 1_000
    {:ok, meta} = Tay.Engine.Admission.metadata(@name)
    [{_, _, ^caller, :submitted, _}] = :ets.lookup(@name, {:schedule, 1})
    used = Memory.used(meta.memory)
    Process.exit(caller, :kill)

    assert {:error, "capacity", _} =
             Tay.Schedule.Coordinator.register(coordinator, %{
               fields
               | "declaration_id" => "excess"
             })

    assert Memory.used(meta.memory) == used
    send(engine, :resume)

    assert EngineHelpers.eventually(fn ->
             [{_, _, _, stage, _}] = :ets.lookup(@name, {:schedule, 1})
             stage == :free
           end)

    state = :sys.get_state(engine)
    assert Memory.used(meta.memory) == state.budget.bytes + state.auxiliary_bytes
    assert {:ok, %{id: "queued"}} = Tay.get_schedule("queued", name: @name)
  end

  defp schedule(id, size) do
    {:ok, schedule} =
      Tay.Schedule.new(
        id,
        %{
          "task" => "worker.v1",
          "every" => %{"hours" => 1},
          "args" => %{"blob" => String.duplicate("x", size)}
        },
        1_000
      )

    schedule
  end
end
