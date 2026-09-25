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
    assert {:ok, recovered} = Schedule.advance_after_delivery(schedule, 61_000, 2_000_000)
    assert recovered.last_at == 61_000
    assert recovered.next_at == 2_761_000
  end

  test "catch-up all preserves each missed interval" do
    assert {:ok, schedule} =
             Schedule.new(
               "schedule-all",
               %{
                 "task" => "reports.rebuild.v1",
                 "every" => %{"seconds" => 30},
                 "catch_up" => "all"
               },
               1_000
             )

    assert {:ok, next} = Schedule.advance_after_delivery(schedule, 1_000, 100_000)
    assert next.next_at == 31_000
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
