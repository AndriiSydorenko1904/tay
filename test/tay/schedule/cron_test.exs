defmodule Tay.Schedule.CronTest do
  use ExUnit.Case, async: true

  alias Tay.Schedule.Cron

  test "evaluates five-field Unix cron in UTC" do
    assert {:ok, cron} = Cron.parse("15 9 * * 1-5")
    after_ms = DateTime.to_unix(~U[2026-01-02 09:14:31.000Z], :millisecond)

    assert {:ok, next} = Cron.next(cron, after_ms)
    assert DateTime.from_unix!(next, :millisecond) == ~U[2026-01-02 09:15:00.000Z]
  end

  test "uses an explicit fixed UTC offset for matching" do
    assert {:ok, cron} = Cron.parse("0 9 * * *", "+02")
    after_ms = DateTime.to_unix(~U[2026-01-02 06:30:00.000Z], :millisecond)

    assert {:ok, next} = Cron.next(cron, after_ms)
    assert DateTime.from_unix!(next, :millisecond) == ~U[2026-01-02 07:00:00.000Z]
  end

  test "keeps Unix day-of-month/day-of-week OR semantics" do
    assert {:ok, cron} = Cron.parse("0 0 13 * 1")
    after_ms = DateTime.to_unix(~U[2026-01-01 00:00:00.000Z], :millisecond)

    assert {:ok, next} = Cron.next(cron, after_ms)
    assert DateTime.from_unix!(next, :millisecond) == ~U[2026-01-05 00:00:00.000Z]
  end

  test "rejects invalid cron fields and offsets" do
    assert {:error, :invalid_cron} = Cron.parse("* * * *")
    assert {:error, :invalid_cron} = Cron.parse("61 * * * *")
    assert {:error, :invalid_cron} = Cron.parse("* * * * *", "Europe/Kyiv")
  end
end
