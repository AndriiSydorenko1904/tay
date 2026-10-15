defmodule Tay.Storage.RecordInspection do
  @moduledoc false

  alias Tay.Event
  alias Tay.Storage.V2.Codec

  @detail_limit 100
  @printable_limit 8_192
  @field_bytes 4_096
  @raw_bytes 16_384

  def preview(record), do: inspect_record(record, false)
  def describe(record), do: inspect_record(record, true)

  defp inspect_record(%{record_type: 7, payload_schema_version: 1, payload: payload}, details?) do
    case Codec.decode_snapshot(payload) do
      {:ok, job} ->
        job = job |> Map.delete(:definition_bytes) |> normalize_identity(:id)

        description(
          "job",
          job.id,
          "#{human_atom(job.state)} · attempt #{job.attempt} · revision #{job.revision}",
          job.revision,
          job.inserted_at,
          job,
          details?
        )

      {:error, reason} ->
        decode_error(reason)
    end
  end

  defp inspect_record(%{record_type: 8, payload_schema_version: 1, payload: payload}, details?) do
    case Codec.decode_mutation(payload) do
      {:ok, mutation} ->
        mutation = normalize_identity(mutation, :job_id)

        description(
          "job",
          mutation.job_id,
          "#{human_atom(mutation.kind)} · revision #{mutation.expected_revision} → #{mutation.new_revision}",
          mutation.new_revision,
          mutation.at,
          mutation,
          details?
        )

      {:error, reason} ->
        decode_error(reason)
    end
  end

  defp inspect_record(
         %{record_type: type, payload_schema_version: schema, payload: payload},
         details?
       ) do
    case Event.decode_payload(type, schema, payload, Tay.Event.Value.defaults()) do
      {:ok, event, _bytes} -> describe_event(event, details?)
      {:error, reason} -> decode_error(reason)
    end
  end

  defp describe_event(%Event{record_type: type, data: data}, details?) do
    name = Tay.Event.V2.type_name(type)
    identity_field = Tay.Event.V2.binary_identity_field(type)
    data = normalize_identity(data, identity_field)
    identity = if identity_field, do: Map.get(data, identity_field)
    entity = if identity_field == "schedule_id", do: "schedule", else: "job"
    revision = revision(data)

    description(
      entity,
      identity,
      event_summary(name, data, revision),
      revision,
      Map.get(data, "at"),
      data,
      details?
    )
  end

  defp event_summary(:job_inserted, data, revision) do
    definition = Map.get(data, "definition", %{})
    worker = Map.get(definition, "worker_key", "unknown worker")
    queue = Map.get(definition, "queue_key", "unknown queue")
    "inserted by #{worker} on #{queue}, revision #{revision}"
  end

  defp event_summary(:job_started, data, revision),
    do: "attempt #{data["attempt"]} started, revision #{revision}"

  defp event_summary(:job_finished, data, revision),
    do: "#{outcome(data["outcome"])} · #{disposition(data["disposition"])} · revision #{revision}"

  defp event_summary(:result_recorded, _data, revision),
    do: "result recorded, revision #{revision}"

  defp event_summary(nil, _data, revision), do: "revision #{revision}"

  defp event_summary(name, _data, revision) when is_atom(name),
    do: "#{name |> Atom.to_string() |> String.replace("_", " ")}, revision #{revision}"

  defp revision(%{"expected_revision" => expected}) when is_integer(expected), do: expected + 1
  defp revision(_), do: nil

  defp description(entity, identity, summary, revision, at, details, details?) do
    preview = %{
      entity: entity,
      identity: identity || "—",
      summary: summary,
      revision: revision,
      at: at
    }

    if details? do
      Map.merge(preview, %{
        fields: detail_fields(details),
        details:
          details
          |> inspect(
            pretty: true,
            limit: @detail_limit,
            printable_limit: @printable_limit
          )
          |> truncate_text(@raw_bytes)
      })
    else
      preview
    end
  end

  defp decode_error(reason) do
    %{
      entity: nil,
      identity: "—",
      summary: "Payload could not be decoded",
      revision: nil,
      at: nil,
      fields: [],
      details: "Decode error: #{inspect(reason)}"
    }
  end

  defp normalize_identity(map, nil), do: map

  defp normalize_identity(map, field) do
    case Map.fetch(map, field) do
      {:ok, id} when is_binary(id) and byte_size(id) == 16 ->
        Map.put(map, field, Tay.JobID.encode(id))

      _ ->
        map
    end
  end

  defp detail_fields(%{kind: kind, body: body} = mutation) when is_map(body) do
    [
      field("Change", human_atom(kind), "The state transition stored by this record."),
      field("Job ID", mutation.job_id, "Stable identifier used to find this job."),
      field(
        "Revision",
        "#{mutation.expected_revision} → #{mutation.new_revision}",
        "The job state changed from the expected revision to the new revision."
      ),
      field("Recorded at", timestamp(mutation.at), "Time written by the transition producer.")
      | body_fields(body)
    ]
  end

  defp detail_fields(%{id: id, state: state, revision: revision} = snapshot) do
    leading = [
      field("Snapshot", human_atom(state), "Job state captured by this compacted snapshot."),
      field("Job ID", id, "Stable identifier used to find this job."),
      field("Revision", revision, "Revision represented by this complete snapshot.")
    ]

    leading ++ map_fields(Map.drop(snapshot, [:id, :state, :revision]))
  end

  defp detail_fields(details) when is_map(details), do: map_fields(details)

  defp body_fields(body) do
    ordered_map_fields(body, [
      "outcome",
      "disposition",
      "execution_token",
      "attempt",
      "next_attempt",
      "next_due_at",
      "due_at",
      "diagnostic",
      "mode",
      "new_due_at",
      "cycle_token",
      "availability_order",
      "eligible_at",
      "definition"
    ])
  end

  defp map_fields(map) do
    ordered_map_fields(map, [
      "kind",
      "job_id",
      "schedule_id",
      "expected_revision",
      "new_revision",
      "at",
      "state",
      "cycle",
      "execution",
      "attempt",
      "next_attempt",
      "outcome",
      "disposition",
      "execution_token",
      "next_due_at",
      "due_at",
      "eligible_at",
      "inserted_at",
      "attempted_at",
      "completed_at",
      "terminal_at",
      "availability_order",
      "diagnostic",
      "definition"
    ])
  end

  defp ordered_map_fields(map, preferred) do
    keyed = Map.new(map, fn {key, value} -> {to_string(key), value} end)
    remaining = keyed |> Map.keys() |> Enum.reject(&(&1 in preferred)) |> Enum.sort()

    for key <- preferred ++ remaining, Map.has_key?(keyed, key) do
      detail_field(key, Map.fetch!(keyed, key))
    end
  end

  defp detail_field("outcome", value) do
    field(
      "Outcome",
      outcome(value),
      "How this execution ended. The numeric wire code is shown for correlation with storage and logs."
    )
  end

  defp detail_field("disposition", value) do
    field(
      "What happens next",
      disposition(value),
      "Whether the job is complete, will be retried, or has been discarded."
    )
  end

  defp detail_field("execution_token", nil),
    do: field("Execution token", "None", "This transition is not tied to a running execution.")

  defp detail_field("execution_token", value) do
    field(
      "Execution token",
      value,
      "Identifies the exact run whose result was accepted; it is not the attempt count. Stale workers with another token cannot overwrite this job."
    )
  end

  defp detail_field("expected_revision", value),
    do: field("Expected revision", value, "Job revision required before applying this event.")

  defp detail_field("new_revision", value),
    do: field("New revision", value, "Job revision after this event was applied.")

  defp detail_field("next_attempt", nil),
    do: field("Next attempt", "Not scheduled", "No further attempt is planned.")

  defp detail_field("next_attempt", value),
    do: field("Next attempt", value, "Attempt number to run next.")

  defp detail_field("next_due_at", nil),
    do: field("Next run", "Not scheduled", "There is no retry deadline.")

  defp detail_field("diagnostic", nil),
    do: field("Diagnostic", "None", "No failure diagnostic was recorded.")

  defp detail_field("diagnostic", %{"code" => code} = value) do
    version = Map.get(value, "version")
    suffix = if version, do: " · format #{version}", else: ""

    field(
      "Diagnostic",
      "#{diagnostic(code)}#{suffix}",
      "Bounded failure classification; details remain in worker logs."
    )
  end

  defp detail_field(key, value)
       when key in [
              "at",
              "due_at",
              "next_due_at",
              "new_due_at",
              "eligible_at",
              "inserted_at",
              "attempted_at",
              "completed_at",
              "terminal_at"
            ] do
    field(label(key), if(is_nil(value), do: "None", else: timestamp(value)), time_help(key))
  end

  defp detail_field("job_id", value),
    do: field("Job ID", value, "Stable identifier used to find this job.")

  defp detail_field("attempt", value),
    do: field("Attempt", value, "Current execution attempt number.")

  defp detail_field("cycle", value),
    do:
      field(
        "Scheduling cycle",
        value,
        "Changes when the job enters a new scheduling cycle and helps reject stale transitions."
      )

  defp detail_field("cycle_token", value),
    do:
      field(
        "Scheduling cycle token",
        value,
        "Confirms that this start belongs to the job's current scheduling cycle."
      )

  defp detail_field("availability_order", value),
    do:
      field(
        "Queue order token",
        printable(value),
        "Stable tie-breaker that preserves queue order for jobs eligible at the same time."
      )

  defp detail_field("execution", nil),
    do: field("Active execution token", "None", "The job is not currently executing.")

  defp detail_field("execution", value),
    do:
      field(
        "Active execution token",
        value,
        "Identifies the run currently allowed to finish or be cancelled."
      )

  defp detail_field("state", value),
    do: field("State", printable(value), "Current lifecycle state of the job.")

  defp detail_field(key, value), do: field(label(key), printable(value))

  defp field(label, value, help \\ nil),
    do: %{label: label, value: value |> to_string() |> truncate_text(@field_bytes), help: help}

  defp label(key),
    do: key |> String.replace("_", " ") |> String.capitalize()

  defp printable(value) when is_atom(value), do: human_atom(value)

  defp printable(value) when is_binary(value) do
    if String.valid?(value),
      do: truncate_text(value, @field_bytes),
      else: inspect(value, binaries: :as_binaries, printable_limit: @field_bytes)
  end

  defp printable(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp printable(value), do: inspect(value, pretty: true, limit: @detail_limit)

  defp human_atom(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp outcome(0), do: "Succeeded (code 0)"
  defp outcome(1), do: "Failed (code 1)"
  defp outcome(2), do: "Timed out (code 2)"
  defp outcome(3), do: "Interrupted (code 3)"
  defp outcome(value), do: "Unknown (code #{value})"

  defp disposition(0), do: "Completed — no retry (code 0)"
  defp disposition(1), do: "Retry scheduled (code 1)"
  defp disposition(2), do: "Discarded — no attempts left (code 2)"
  defp disposition(value), do: "Unknown (code #{value})"

  defp diagnostic(1), do: "Task reported a failure (code 1)"
  defp diagnostic(2), do: "Task raised an exception (code 2)"
  defp diagnostic(3), do: "Task threw a value (code 3)"
  defp diagnostic(4), do: "Task process exited (code 4)"
  defp diagnostic(5), do: "Execution timed out (code 5)"
  defp diagnostic(6), do: "Task returned an unsupported value (code 6)"
  defp diagnostic(7), do: "Execution was interrupted (code 7)"
  defp diagnostic(code), do: "Unknown diagnostic (code #{code})"

  defp timestamp(milliseconds) when is_integer(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, datetime} ->
        "#{Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S.%3f UTC")} · #{milliseconds} ms"

      {:error, _} ->
        "#{milliseconds} ms"
    end
  end

  defp timestamp(value), do: printable(value)

  defp truncate_text(value, limit) when byte_size(value) <= limit, do: value

  defp truncate_text(value, limit) do
    prefix = valid_prefix(value, limit)
    omitted = byte_size(value) - byte_size(prefix)
    "#{prefix}… [truncated; #{omitted} bytes omitted]"
  end

  defp valid_prefix(value, limit) do
    prefix = binary_part(value, 0, limit)

    if String.valid?(prefix),
      do: prefix,
      else: valid_prefix(value, limit - 1)
  end

  defp time_help("at"), do: "Time written by the event producer."
  defp time_help("next_due_at"), do: "Earliest time at which the retry may run."
  defp time_help("due_at"), do: "Time at which this job became due."
  defp time_help("new_due_at"), do: "Updated time at which this job becomes due."
  defp time_help(_), do: nil
end
