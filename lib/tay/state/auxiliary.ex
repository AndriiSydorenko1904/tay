defmodule Tay.State.Auxiliary do
  @moduledoc false

  alias Tay.Event

  def reduce(%Event{record_type: type, data: data} = event, %{sequence: sequence}, candidate)
      when type in 7..10 do
    with {:ok, _} <- Event.encode(event, candidate.value_limits),
         true <- Tay.Event.V2.sequence?(sequence) || {:error, :invalid_position} do
      apply_event(type, data, sequence, candidate)
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
        cancelled_at: nil
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

  def canonical_events(candidate, first_sequence) do
    schedules = candidate.schedules |> Map.values() |> Enum.sort_by(& &1.id)

    {schedule_events, next} =
      Enum.reduce(schedules, {[], first_sequence}, fn schedule, {events, sequence} ->
        definition = schedule.definition
        initial_next = schedule.last_at || schedule.next_at

        registered = %Event{
          record_type: 7,
          payload_schema_version: 2,
          data: %{
            "at" => schedule.registered_at,
            "definition" => definition,
            "expected_revision" => 0,
            "next_at" => initial_next,
            "schedule_id" => schedule.id
          }
        }

        {events, revision, sequence} = {[registered | events], sequence, sequence + 1}

        {events, revision, sequence} =
          if schedule.last_at do
            advanced = %Event{
              record_type: 8,
              payload_schema_version: 2,
              data: %{
                "at" => max(schedule.last_at, schedule.registered_at),
                "due_at" => schedule.last_at,
                "expected_revision" => revision,
                "next_at" => schedule.next_at,
                "schedule_id" => schedule.id
              }
            }

            {[advanced | events], sequence, sequence + 1}
          else
            {events, revision, sequence}
          end

        if schedule.cancelled_at do
          cancelled = %Event{
            record_type: 9,
            payload_schema_version: 2,
            data: %{
              "at" => schedule.cancelled_at,
              "expected_revision" => revision,
              "schedule_id" => schedule.id
            }
          }

          {[cancelled | events], sequence + 1}
        else
          {events, sequence}
        end
      end)

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

    {Enum.reverse(schedule_events) ++ result_events, next}
  end
end
