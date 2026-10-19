defmodule Tay.Storage.RecordInspectionTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.RecordInspection
  alias Tay.Storage.V2.Codec

  test "explains finished mutation wire values without hiding the raw payload" do
    id = <<1::128>>

    mutation = %{
      job_id: id,
      kind: :finished,
      expected_revision: 2,
      new_revision: 3,
      at: 1_792_047_699_117,
      body: %{
        "diagnostic" => nil,
        "disposition" => 0,
        "execution_token" => 2,
        "next_attempt" => nil,
        "next_due_at" => nil,
        "outcome" => 0
      }
    }

    assert {:ok, payload} = Codec.encode_mutation(mutation)

    record = %{
      record_type: Codec.mutation_type(),
      payload_schema_version: Codec.schema(),
      payload: payload
    }

    preview = RecordInspection.preview(record)
    refute Map.has_key?(preview, :fields)
    refute Map.has_key?(preview, :details)

    inspection = RecordInspection.describe(record)

    fields = Map.new(inspection.fields, &{&1.label, &1})

    assert inspection.summary ==
             "Finished · revision 2 → 3"

    assert fields["Outcome"].value == "Succeeded (code 0)"
    assert fields["What happens next"].value == "Completed — no retry (code 0)"
    assert fields["Execution token"].value == "2"
    assert fields["Execution token"].help =~ "not the attempt count"
    assert fields["Next attempt"].value == "Not scheduled"
    assert fields["Next run"].value == "Not scheduled"
    assert fields["Diagnostic"].value == "None"
    assert inspection.details =~ ~s("disposition" => 0)
  end

  test "bounds individual values and the complete raw representation" do
    event = %Tay.Event{
      record_type: 10,
      payload_schema_version: 2,
      data: %{
        "at" => 1,
        "expected_revision" => 1,
        "job_id" => <<1::128>>,
        "result" => %{"body" => String.duplicate("x", 100_000)}
      }
    }

    assert {:ok, {type, schema, payload}} = Tay.Event.encode(event)

    inspection =
      RecordInspection.describe(%{
        record_type: type,
        payload_schema_version: schema,
        payload: payload
      })

    result = Enum.find(inspection.fields, &(&1.label == "Result"))
    assert result.value =~ "truncated"
    assert byte_size(result.value) < 4_200
    assert inspection.details =~ "<> ..."
    assert byte_size(inspection.details) < 16_500
  end
end
