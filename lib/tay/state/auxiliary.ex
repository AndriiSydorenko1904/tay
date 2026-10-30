defmodule Tay.State.Auxiliary do
  require Tay.Event.V2
  @moduledoc false

  alias Tay.Event

  def reduce(%Event{record_type: type, data: data} = event, %{sequence: sequence}, candidate)
      when Tay.Event.V2.is_auxiliary(type) do
    with {:ok, _} <- Event.encode(event, candidate.value_limits),
         true <- Tay.Event.V2.sequence?(sequence) || {:error, :invalid_position} do
      with {:ok, next} <- apply_event(type, data, sequence, candidate) do
        old = entry_bytes(candidate, type, data)
        added = entry_bytes(next, type, data)
        bytes = candidate.bytes - old + added

        with :ok <- Tay.State.Memory.check(candidate.limits, bytes) do
          {:ok, %{next | bytes: bytes, auxiliary_bytes: candidate.auxiliary_bytes - old + added}}
        end
      end
    end
  end

  def reduce(_, _, _), do: {:error, :invalid_auxiliary_event}

  defp apply_event(7, data, sequence, candidate) do
    previous = Map.get(candidate.schedules, data["schedule_id"])

    if data["expected_revision"] == if(previous, do: previous.revision, else: 0) do
      schedule = %{
        id: data["schedule_id"],
        definition: data["definition"],
        revision: sequence,
        registered_at: data["at"],
        next_at: data["next_at"],
        last_at: nil,
        cancelled_at: nil,
        active_job_id: nil,
        active_job_ids: [],
        membership_complete: false
      }

      {:ok, %{candidate | schedules: Map.put(candidate.schedules, schedule.id, schedule)}}
    else
      {:error, :revision_conflict}
    end
  end

  defp apply_event(8, data, sequence, candidate) do
    with %{cancelled_at: nil} = schedule <- Map.get(candidate.schedules, data["schedule_id"]),
         true <- schedule.revision == data["expected_revision"] || {:error, :revision_conflict},
         true <- schedule.next_at == data["due_at"] || {:error, :due_conflict} do
      next = %{
        schedule
        | revision: sequence,
          last_at: data["due_at"],
          next_at: data["next_at"]
      }

      {:ok, %{candidate | schedules: Map.put(candidate.schedules, schedule.id, next)}}
    else
      nil -> {:error, :missing_schedule}
      %{cancelled_at: _} -> {:error, :cancelled_schedule}
      error -> error
    end
  end

  defp apply_event(12, data, _sequence, candidate) do
    id = data["schedule_id"]

    previous = Map.get(candidate.schedules, id)

    if data["expected_revision"] != if(previous, do: previous.revision, else: 0) do
      {:error, :revision_conflict}
    else
      schedule = %{
        id: id,
        definition: data["definition"],
        revision: data["revision"],
        registered_at: data["registered_at"],
        next_at: data["next_at"],
        last_at: data["last_at"],
        cancelled_at: data["cancelled_at"],
        active_job_id: data["active_job_id"],
        active_job_ids:
          if(previous,
            do: Map.get(previous, :active_job_ids, []),
            else: List.wrap(data["active_job_id"])
          ),
        membership_complete:
          if(previous, do: Map.get(previous, :membership_complete, false), else: false)
      }

      {:ok, %{candidate | schedules: Map.put(candidate.schedules, id, schedule)}}
    end
  end

  defp apply_event(13, data, sequence, candidate) do
    with {:ok, next} <- apply_event(12, data, sequence, candidate) do
      schedule = next.schedules[data["schedule_id"]]

      schedule = %{
        schedule
        | active_job_ids: data["active_job_ids"],
          membership_complete: data["membership_complete"]
      }

      {:ok, %{next | schedules: Map.put(next.schedules, schedule.id, schedule)}}
    end
  end

  defp apply_event(11, data, sequence, candidate) do
    with {:ok, next} <- apply_event(8, data, sequence, candidate) do
      id = data["schedule_id"]

      schedule =
        next.schedules[id]
        |> Map.put(:active_job_id, data["active_job_id"])
        |> Map.put(:revision, data["expected_revision"] + 1)
        |> Map.put(
          :active_job_ids,
          active_members(
            candidate.jobs,
            Map.get(next.schedules[id], :active_job_ids, []) ++ List.wrap(data["active_job_id"])
          )
        )

      {:ok, %{next | schedules: Map.put(next.schedules, id, schedule)}}
    end
  end

  defp apply_event(9, data, sequence, candidate) do
    with %{} = schedule <- Map.get(candidate.schedules, data["schedule_id"]),
         true <- schedule.revision == data["expected_revision"] || {:error, :revision_conflict} do
      next = %{schedule | revision: sequence, cancelled_at: data["at"]}
      {:ok, %{candidate | schedules: Map.put(candidate.schedules, schedule.id, next)}}
    else
      nil -> {:error, :missing_schedule}
      error -> error
    end
  end

  defp apply_event(10, data, _sequence, candidate) do
    with %{state: :completed, revision: revision} <- Map.get(candidate.jobs, data["job_id"]),
         true <- revision == data["expected_revision"] || {:error, :revision_conflict} do
      result = %{value: data["result"], recorded_at: data["at"], job_revision: revision}
      {:ok, %{candidate | results: Map.put(candidate.results, data["job_id"], result)}}
    else
      nil -> {:error, :missing_job}
      %{state: _} -> {:error, :job_not_completed}
      error -> error
    end
  end

  def active_members(jobs, ids) do
    ids
    |> Enum.uniq()
    |> Enum.filter(fn encoded ->
      case Tay.JobID.decode(encoded) do
        {:ok, raw} ->
          case Map.get(jobs, raw) do
            %{state: state} -> state not in [:completed, :cancelled, :discarded]
            _ -> false
          end

        _ ->
          false
      end
    end)
    |> Enum.sort()
  end

  def replace_owners(owners, previous, next) do
    previous_ids = if previous, do: Map.get(previous, :active_job_ids, []), else: []

    owners =
      Enum.reduce(previous_ids, owners, fn encoded, acc ->
        case Tay.JobID.decode(encoded) do
          {:ok, raw} -> Map.delete(acc, raw)
          _ -> acc
        end
      end)

    Enum.reduce(Map.get(next, :active_job_ids, []), owners, fn encoded, acc ->
      case Tay.JobID.decode(encoded) do
        {:ok, raw} -> Map.put(acc, raw, next.id)
        _ -> acc
      end
    end)
  end

  def owners(schedules) do
    for {id, schedule} <- schedules,
        encoded <- Map.get(schedule, :active_job_ids, []),
        {:ok, raw} <- [Tay.JobID.decode(encoded)],
        into: %{},
        do: {raw, id}
  end

  defp entry_bytes(candidate, 10, data),
    do: Tay.State.Memory.result_bytes(Map.get(candidate.results, data["job_id"]))

  defp entry_bytes(candidate, _, data),
    do: Tay.State.Memory.schedule_bytes(Map.get(candidate.schedules, data["schedule_id"]))

  def canonical_events(candidate, first_sequence) do
    schedules = candidate.schedules |> Map.values() |> Enum.sort_by(& &1.id)

    schedule_events =
      Enum.map(schedules, fn schedule ->
        %Event{
          record_type: 13,
          payload_schema_version: 2,
          data: %{
            "at" => schedule.registered_at,
            "expected_revision" => 0,
            "schedule_id" => schedule.id,
            "definition" => schedule.definition,
            "registered_at" => schedule.registered_at,
            "revision" => schedule.revision,
            "last_at" => schedule.last_at,
            "next_at" => schedule.next_at,
            "cancelled_at" => schedule.cancelled_at,
            "active_job_id" => Map.get(schedule, :active_job_id),
            "active_job_ids" => Map.get(schedule, :active_job_ids, []),
            "membership_complete" => Map.get(schedule, :membership_complete, false)
          }
        }
      end)

    next = first_sequence + length(schedule_events)

    result_events =
      candidate.results
      |> Enum.filter(fn {id, _} -> match?(%{state: :completed}, candidate.jobs[id]) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, result} ->
        %Event{
          record_type: 10,
          payload_schema_version: 2,
          data: %{
            "at" => result.recorded_at,
            "expected_revision" => candidate.jobs[id].revision,
            "job_id" => id,
            "result" => result.value
          }
        }
      end)

    {schedule_events ++ result_events, next}
  end
end
