defmodule Tay.Engine.ScheduleOverlapTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Core.Local
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  for policy <- ["allow", "skip", "queue"] do
    @policy policy
    test "#{policy} remains authoritative across compaction and restart", %{path: path} do
      {:ok, root} = EngineHelpers.start(path, @name)

      {:ok, schedule} =
        Tay.Schedule.new(
          "overlap",
          %{
            "task" => "worker.v1",
            "args" => %{},
            "every" => %{"seconds" => 1},
            "overlap" => @policy,
            "catch_up" => "all"
          },
          1000
        )

      assert {:ok, _} = Tay.register_schedule(schedule, name: @name)
      assert {:ok, delivered} = Local.deliver_schedule(@name, schedule, 1000, 2000, 1000)
      first_id = Tay.Schedule.occurrence_id(schedule.id, 1000)
      assert delivered.active_job_id == first_id
      assert {:ok, %{state: :available}} = Tay.get_job(first_id, name: @name)
      # Repeating a delivered occurrence never admits another job.
      assert {:ok, ^delivered} = Local.deliver_schedule(@name, schedule, 1000, 2000, 1000)

      # Interleave unrelated history so physical checkpoint coordinates differ.
      assert {:ok, _} = Tay.insert(EngineWorker.new(%{"unrelated" => true}), name: @name)
      second = Local.deliver_schedule(@name, schedule, 2000, 3000, 2000)

      case @policy do
        "allow" ->
          assert {:ok, %{active_job_id: id}} = second
          assert id == Tay.Schedule.occurrence_id(schedule.id, 2000)

        "skip" ->
          assert {:ok, %{active_job_id: ^first_id, next_at: 3000}} = second

          assert {:error, :not_found} =
                   Tay.get_job(Tay.Schedule.occurrence_id(schedule.id, 2000), name: @name)

        "queue" ->
          assert {:error, %Tay.Error{reason: :schedule_overlap}} = second
      end

      assert {:ok, [before]} = Tay.schedules(name: @name)
      assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000)
      assert {:ok, [^before]} = Tay.schedules(name: @name)
      checkpoint_at = Tay.status(name: @name).last_checkpoint_at
      EngineHelpers.stop(root)
      {:ok, root} = EngineHelpers.restart(path, @name)

      on_exit(fn ->
        try do
          EngineHelpers.stop(root)
        catch
          :exit, _ -> :ok
        end
      end)

      assert {:ok, [^before]} = Tay.schedules(name: @name)
      assert Tay.status(name: @name).last_checkpoint_at == checkpoint_at

      if @policy in ["skip", "queue"] do
        assert {:ok, _} = Tay.cancel(first_id, name: @name)
        due = before.next_at
        assert {:ok, next} = Local.deliver_schedule(@name, schedule, due, due + 1000, due)
        assert next.active_job_id == Tay.Schedule.occurrence_id(schedule.id, due)
        assert {:ok, %{state: :available}} = Tay.get_job(next.active_job_id, name: @name)
      end
    end
  end

  for policy <- ["skip", "queue"] do
    @tightened policy
    test "allow to #{policy} observes older occurrences after out-of-order completion and checkpoints",
         %{path: path} do
      {:ok, root} = EngineHelpers.start(path, @name)
      fields = %{"task" => "worker.v1", "every" => %{"seconds" => 1}, "overlap" => "allow"}
      {:ok, allow} = Tay.Schedule.new("tightening", fields, 1_000)
      assert {:ok, _} = Tay.register_schedule(allow, name: @name)
      assert {:ok, first} = Local.deliver_schedule(@name, allow, 1_000, 2_000, 1_000)
      assert {:ok, latest} = Local.deliver_schedule(@name, allow, 2_000, 3_000, 2_000)
      assert {:ok, _} = Tay.cancel(latest.active_job_id, name: @name)
      assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000)
      EngineHelpers.stop(root)
      {:ok, root} = EngineHelpers.restart(path, @name)

      on_exit(fn ->
        try do
          EngineHelpers.stop(root)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, tightened} = Tay.Schedule.new(allow.id, Map.put(fields, "overlap", @tightened), 3_000)
      assert {:ok, _} = Tay.register_schedule(tightened, name: @name)
      result = Local.deliver_schedule(@name, tightened, 3_000, 4_000, 3_000)

      if @tightened == "skip" do
        assert {:ok, %{next_at: 4_000}} = result
      else
        assert {:error, %Tay.Error{reason: :schedule_overlap}} = result
      end

      assert {:error, :not_found} =
               Tay.get_job(Tay.Schedule.occurrence_id(allow.id, 3_000), name: @name)

      assert {:ok, _} = Tay.cancel(first.active_job_id, name: @name)
      {:ok, state} = Tay.get_schedule(allow.id, name: @name)

      assert {:ok, next} =
               Local.deliver_schedule(
                 @name,
                 tightened,
                 state.next_at,
                 state.next_at + 1_000,
                 state.next_at
               )

      assert next.active_job_id == Tay.Schedule.occurrence_id(allow.id, state.next_at)
    end
  end

  test "compaction retains overlap membership of queued volatile occurrences", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    fields = %{
      "task" => "worker.v1",
      "every" => %{"seconds" => 1},
      "overlap" => "allow",
      "options" => %{"durability" => "volatile"}
    }

    {:ok, allow} = Tay.Schedule.new("volatile-overlap", fields, 1_000)
    assert {:ok, _} = Tay.register_schedule(allow, name: @name)
    assert {:ok, first} = Local.deliver_schedule(@name, allow, 1_000, 2_000, 1_000)
    assert {:ok, last} = Local.deliver_schedule(@name, allow, 2_000, 3_000, 2_000)
    assert {:ok, _} = Tay.cancel(last.active_job_id, name: @name)
    assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000)
    {:ok, skip} = Tay.Schedule.new(allow.id, Map.put(fields, "overlap", "skip"), 3_000)
    assert {:ok, _} = Tay.register_schedule(skip, name: @name)
    assert {:ok, %{active_job_id: id}} = Local.deliver_schedule(@name, skip, 3_000, 4_000, 3_000)
    assert id == last.active_job_id

    assert {:error, :not_found} =
             Tay.get_job(Tay.Schedule.occurrence_id(skip.id, 3_000), name: @name)

    assert {:ok, %{state: :available}} = Tay.get_job(first.active_job_id, name: @name)
    state = :sys.get_state(EngineHelpers.engine(root))
    assert Tay.State.Memory.used(state.memory) == state.budget.bytes + state.auxiliary_bytes
  end

  test "skip retains the busy job across several skipped occurrences", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, schedule} =
      Tay.Schedule.new(
        "skip-many",
        %{"task" => "worker.v1", "every" => %{"seconds" => 1}, "overlap" => "skip"},
        1000
      )

    assert {:ok, _} = Tay.register_schedule(schedule, name: @name)
    assert {:ok, first} = Local.deliver_schedule(@name, schedule, 1000, 2000, 1000)

    for due <- [2000, 3000, 4000] do
      assert {:ok, current} = Local.deliver_schedule(@name, schedule, due, due + 1000, due)
      assert current.active_job_id == first.active_job_id
    end

    assert Tay.status(name: @name).jobs == 1
  end

  test "a VM-generation loss between insertion and advancement reconciles the same job", %{
    path: path
  } do
    owner = self()

    hook = fn
      {:execution, 1, :post_append} ->
        send(owner, {:insert_committed, self()})

        receive do
          :release -> :ok
        end

      _ ->
        :ok
    end

    {:ok, root} = EngineHelpers.start(path, @name, test_hook: hook)

    {:ok, schedule} =
      Tay.Schedule.new(
        "partial-delivery",
        %{"task" => "worker.v1", "every" => %{"seconds" => 1}, "overlap" => "queue"},
        1000
      )

    assert {:ok, _} = Tay.register_schedule(schedule, name: @name)
    delivery = Task.async(fn -> Local.deliver_schedule(@name, schedule, 1000, 2000, 1000) end)
    assert_receive {:insert_committed, engine}, 1000
    Process.exit(engine, :kill)
    assert {:error, %Tay.Error{kind: :unknown_outcome}} = Task.await(delivery, 8_000)
    EngineHelpers.stop(root)
    {:ok, root} = EngineHelpers.restart(path, @name)

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    assert {:ok, _} = Local.deliver_schedule(@name, schedule, 1000, 2000, 1000)
    assert Tay.status(name: @name).jobs == 1
    assert {:ok, [%{next_at: 2000, active_job_id: id}]} = Tay.schedules(name: @name)
    assert id == Tay.Schedule.occurrence_id(schedule.id, 1000)
  end
end
