defmodule Tay.Storage.RecordInspection do
  @moduledoc false

  alias Tay.Event
  alias Tay.Storage.V2.Codec

  @detail_limit 100
  @printable_limit 8_192

  def describe(%{record_type: 7, payload_schema_version: 1, payload: payload}) do
    case Codec.decode_snapshot(payload) do
      {:ok, job} ->
        job = job |> Map.delete(:definition_bytes) |> normalize_identity(:id)

        description(
          "job",
          job.id,
          "state #{job.state}, attempt #{job.attempt}, revision #{job.revision}",
          job.revision,
          job.inserted_at,
          job
        )

      {:error, reason} ->
        decode_error(reason)
    end
  end

  def describe(%{record_type: 8, payload_schema_version: 1, payload: payload}) do
    case Codec.decode_mutation(payload) do
      {:ok, mutation} ->
        mutation = normalize_identity(mutation, :job_id)

        description(
          "job",
          mutation.job_id,
          "#{mutation.kind}, revision #{mutation.expected_revision} → #{mutation.new_revision}",
          mutation.new_revision,
          mutation.at,
          mutation
        )

      {:error, reason} ->
        decode_error(reason)
    end
  end

  def describe(%{record_type: type, payload_schema_version: schema, payload: payload}) do
    case Event.decode_payload(type, schema, payload, Tay.Event.Value.defaults()) do
      {:ok, event, _bytes} -> describe_event(event)
      {:error, reason} -> decode_error(reason)
    end
  end

  defp describe_event(%Event{record_type: type, data: data}) do
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
      data
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
    do: "#{data["outcome"]} / #{data["disposition"]}, revision #{revision}"

  defp event_summary(:result_recorded, _data, revision),
    do: "result recorded, revision #{revision}"

  defp event_summary(nil, _data, revision), do: "revision #{revision}"

  defp event_summary(name, _data, revision) when is_atom(name),
    do: "#{name |> Atom.to_string() |> String.replace("_", " ")}, revision #{revision}"

  defp revision(%{"expected_revision" => expected}) when is_integer(expected), do: expected + 1
  defp revision(_), do: nil

  defp description(entity, identity, summary, revision, at, details) do
    %{
      entity: entity,
      identity: identity || "—",
      summary: summary,
      revision: revision,
      at: at,
      details:
        inspect(details, pretty: true, limit: @detail_limit, printable_limit: @printable_limit)
    }
  end

  defp decode_error(reason) do
    %{
      entity: nil,
      identity: "—",
      summary: "Payload could not be decoded",
      revision: nil,
      at: nil,
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
end
