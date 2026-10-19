defmodule Tay.Event.V2CompatibilityTest do
  use ExUnit.Case, async: true

  alias Tay.Event
  alias Tay.Event.{V2, Value}
  alias Tay.Storage.Record
  alias Tay.Test.EventHelpers, as: H

  test "V2 owns every frozen V1 literal without changing its bytes" do
    for id <- ~w(E1 E2 E3 E4 E5 E6) do
      bytes = H.fixture(id)
      assert {:ok, record, <<>>} = Record.decode(bytes)
      event = H.expected(id)

      assert :ok = V2.validate(record.record_type, 1, event.data)
      assert V2.legacy_type?(record.record_type)
      assert Event.supported_schema?(record.record_type, 1)

      assert {:ok, decoded, consumed} =
               Event.decode_payload(record.record_type, 1, record.payload, Value.defaults())

      assert decoded == event
      assert consumed == byte_size(record.payload)
      assert {:ok, {type, 1, payload}} = Event.encode(event)
      assert type == record.record_type
      assert payload == record.payload
      assert {:ok, ^bytes} = Record.encode(%{record | payload: payload})
    end
  end

  test "V2 distinguishes the frozen six-type subset from its new types" do
    refute V2.legacy_type?(7)
    assert V2.v2_type?(7)
  end

  test "event names make numeric wire codes explicit" do
    assert V2.type_name(2) == :job_available
    assert V2.type_name(3) == :job_started
    assert V2.type_name(9) == :schedule_cancelled

    assert V2.type_code(:job_available) == 2
    assert V2.type_code(:job_started) == 3
    assert V2.type_code(:schedule_cancelled) == 9

    assert V2.type_name(255) == nil
    assert V2.type_code(:unknown) == nil
  end

  test "V2 types 7 through 10 use schema 2 and have canonical round trips" do
    definition = %{
      "args" => %{"invoice" => "inv-42"},
      "catch_up" => "latest",
      "expression" => "*/5 * * * *",
      "kind" => "cron",
      "options" => %{"queue" => "billing", "retries" => 3},
      "overlap" => "skip",
      "task" => "billing.capture.v1",
      "timezone" => "+02:00"
    }

    events = [
      %Event{
        record_type: 7,
        payload_schema_version: 2,
        data: %{
          "at" => 100,
          "expected_revision" => 0,
          "schedule_id" => "billing-every-five-minutes",
          "definition" => definition,
          "next_at" => 300_000
        }
      },
      %Event{
        record_type: 8,
        payload_schema_version: 2,
        data: %{
          "at" => 300_001,
          "expected_revision" => 1,
          "schedule_id" => "billing-every-five-minutes",
          "due_at" => 300_000,
          "next_at" => 600_000
        }
      },
      %Event{
        record_type: 9,
        payload_schema_version: 2,
        data: %{
          "at" => 300_002,
          "expected_revision" => 2,
          "schedule_id" => "billing-every-five-minutes"
        }
      },
      %Event{
        record_type: 10,
        payload_schema_version: 2,
        data: %{
          "at" => 300_003,
          "expected_revision" => 3,
          "job_id" => H.id(),
          "result" => %{"captured" => true, "receipt" => "r-1"}
        }
      }
    ]

    for event <- events do
      assert Event.known_type?(event.record_type)
      assert Event.supported_schema?(event.record_type, 2)
      refute Event.supported_schema?(event.record_type, 1)
      assert {:ok, {type, 2, payload}} = Event.encode(event)
      assert type == event.record_type
      assert {:ok, ^event, consumed} = Event.decode_payload(type, 2, payload, Value.defaults())
      assert consumed == byte_size(payload)

      assert {:error, :invalid_event} =
               Event.encode(%{event | data: Map.put(event.data, "extra", nil)})
    end
  end
end
