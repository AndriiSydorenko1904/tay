defmodule Tay.Event.RC3ContractTest do
  use ExUnit.Case, async: true
  alias Tay.Event
  alias Tay.Event.Value

  test "overlap and checkpoint events match independent frozen payloads" do
    fixtures =
      __DIR__ |> Path.join("../../fixtures/events/v2/rc3.json") |> File.read!() |> Jason.decode!()

    for fixture <- fixtures do
      type = fixture["type"]
      payload = Base.decode16!(fixture["payload_hex"], case: :lower)
      event = %Event{record_type: type, payload_schema_version: 2, data: fixture["data"]}
      assert {:ok, {^type, 2, ^payload}} = Event.encode(event)
      assert {:ok, ^event, consumed} = Event.decode_payload(type, 2, payload, Value.defaults())
      assert consumed == byte_size(payload)
      refute Event.supported_schema?(type, 1)

      assert {:error, :invalid_event} =
               Event.encode(%{event | data: Map.put(event.data, "extra", nil)})

      assert {:error, :invalid_event} =
               Event.encode(%{
                 event
                 | data: Map.put(event.data, "active_job_id", String.duplicate("0", 32))
               })
    end
  end

  test "schedule revisions are independent of compaction tail coordinates" do
    fixtures =
      __DIR__ |> Path.join("../../fixtures/events/v2/rc3.json") |> File.read!() |> Jason.decode!()

    checkpoint = Enum.find(fixtures, &(&1["type"] == 12))
    candidate = Tay.Storage.V2.Reducer.candidate()
    event = %Event{record_type: 12, payload_schema_version: 2, data: checkpoint["data"]}
    assert {:ok, before} = Tay.State.Auxiliary.reduce(event, %{sequence: 1}, candidate)

    delivery = %Event{
      record_type: 11,
      payload_schema_version: 2,
      data: %{
        "schedule_id" => "stable",
        "expected_revision" => 37,
        "at" => 2000,
        "due_at" => 2000,
        "next_at" => 3000,
        "active_job_id" => "00000000000000000000000000000002"
      }
    }

    assert {:ok, live} = Tay.State.Auxiliary.reduce(delivery, %{sequence: 1000}, before)
    assert {:ok, tail} = Tay.State.Auxiliary.reduce(delivery, %{sequence: 2}, before)
    assert live.schedules == tail.schedules
    assert live.schedules["stable"].revision == 38
    {[saved], _} = Tay.State.Auxiliary.canonical_events(live, 1)
    assert {:ok, restored} = Tay.State.Auxiliary.reduce(saved, %{sequence: 1}, candidate)
    assert restored.schedules == live.schedules
  end
end
