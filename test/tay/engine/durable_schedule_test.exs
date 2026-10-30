defmodule Tay.Engine.DurableScheduleTest do
  use ExUnit.Case, async: false

  alias Tay.Test.{EngineHelpers, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "schedule registration, advancement, cancellation and compaction survive restart", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.start(path, @name)

    {:ok, schedule} =
      Tay.Schedule.new(
        "reports-hourly",
        %{
          "task" => "reports.build.v1",
          "args" => %{"account" => "a-1"},
          "every" => %{"hours" => 1},
          "options" => %{"queue" => "default"}
        },
        1_000
      )

    assert {:ok, registered} = Tay.register_schedule(schedule, name: @name)
    assert registered.revision == 1
    assert {:ok, [listed]} = Tay.schedules(name: @name)
    assert listed.id == "reports-hourly"

    assert {:ok, advanced} =
             Tay.advance_schedule(
               listed.id,
               listed.revision,
               listed.next_at,
               listed.next_at + 3_600_000,
               listed.next_at,
               name: @name
             )

    assert advanced.last_at == listed.next_at
    assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000)
    assert {:ok, %{records: records}} = Tay.storage_records(1, name: @name)
    assert Enum.any?(records, &(&1.payload_schema_version == 2 and &1.record_type == 13))
    EngineHelpers.stop(root)

    {:ok, root} = EngineHelpers.restart(path, @name)
    assert {:ok, [recovered]} = Tay.schedules(name: @name)
    assert recovered.last_at == listed.next_at
    assert recovered.next_at == listed.next_at + 3_600_000

    assert {:ok, cancelled} = Tay.cancel_schedule(recovered.id, name: @name)
    assert cancelled.cancelled_at
    EngineHelpers.stop(root)

    {:ok, root} = EngineHelpers.restart(path, @name)
    assert {:ok, [%{cancelled_at: cancelled_at}]} = Tay.schedules(name: @name)
    assert is_integer(cancelled_at)
    EngineHelpers.stop(root)
  end
end
