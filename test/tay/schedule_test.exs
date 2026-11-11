defmodule Tay.ScheduleTest do
  use ExUnit.Case, async: true

  alias Tay.Schedule

  test "cron declarations never precede their first allowed time" do
    now = DateTime.to_unix(~U[2026-11-11 12:34:10.000Z], :millisecond)
    next_minute = DateTime.to_unix(~U[2026-11-11 12:35:00.000Z], :millisecond)
    fields = %{"task" => "reports.rebuild.v1", "cron" => "* * * * *"}

    for timing <- [
          %{},
          %{"delay" => 30},
          %{"start_at" => now + 30_000},
          %{"start_at" => next_minute}
        ] do
      assert {:ok, schedule} = Schedule.new("cron-start", Map.merge(fields, timing), now)
      assert schedule.next_at == next_minute
    end
  end

  test "cron declarations include matching minute boundaries, including the Unix epoch" do
    for start_at <- [0, 60_000] do
      assert {:ok, schedule} =
               Schedule.new(
                 "cron-boundary",
                 %{
                   "task" => "reports.rebuild.v1",
                   "cron" => "* * * * *",
                   "start_at" => start_at
                 },
                 0
               )

      assert schedule.next_at == start_at
    end
  end

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
