defmodule Tay.ScheduleTest do
  use ExUnit.Case, async: true

  alias Tay.Schedule

  test "builds an interval schedule with delayed first run and skip default" do
    assert {:ok, schedule} =
             Schedule.new(
               "schedule-1",
               %{"task" => "reports.rebuild.v1", "every" => %{"minutes" => 15}, "delay" => 60},
               1_000
             )

    assert schedule.overlap == "skip"
    assert schedule.catch_up == "latest"
    assert schedule.next_at == 61_000
    assert {:ok, next} = Schedule.advance(schedule, 61_000)
    assert next.next_at == 961_000
  end

  test "rejects ambiguous timing and invalid policies" do
    assert {:error, :invalid_schedule} =
             Schedule.new(
               "schedule-1",
               %{
                 "task" => "reports.rebuild.v1",
                 "cron" => "* * * * *",
                 "every" => %{"minutes" => 1}
               },
               0
             )

    assert {:error, :invalid_schedule} =
             Schedule.new(
               "schedule-1",
               %{
                 "task" => "reports.rebuild.v1",
                 "every" => %{"minutes" => 1},
                 "overlap" => "bad"
               },
               0
             )
  end
end
