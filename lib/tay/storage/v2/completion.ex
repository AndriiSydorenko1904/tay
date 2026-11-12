defmodule Tay.Storage.V2.Completion do
  @moduledoc "Atomic successful external completion and result, semantic type 14/schema 2."
  alias Tay.Event
  alias Tay.Execution.Outcome
  alias Tay.State.Auxiliary
  alias Tay.Storage.V2.{Mutation, Reducer}

  def event(job, at, result) do
    %Event{
      record_type: 14,
      payload_schema_version: 2,
      data: %{
        "job_id" => job.id,
        "expected_revision" => job.revision,
        "execution_token" => job.execution,
        "at" => at,
        "result" => result
      }
    }
  end

  def reduce(candidate, %Event{data: data} = event, position) do
    with {:ok, _} <- Event.encode(event, candidate.value_limits),
         true <- Tay.Event.V2.sequence?(position.sequence) || {:error, :invalid_position},
         %{state: :executing} = previous <- Map.get(candidate.jobs, data["job_id"]),
         true <- previous.revision == data["expected_revision"] || {:error, :revision_conflict},
         true <- previous.execution == data["execution_token"] || {:error, :execution_conflict},
         {:ok, finished} <- Outcome.event(previous, :success, data["at"]),
         {:ok, mutation} <-
           Mutation.from_event(finished, previous, candidate.next_availability_order),
         {:ok, completed} <- Reducer.apply(candidate, mutation) do
      Auxiliary.reduce(
        %Event{
          record_type: 10,
          payload_schema_version: 2,
          data: %{
            "job_id" => previous.id,
            "expected_revision" => previous.revision + 1,
            "at" => data["at"],
            "result" => data["result"]
          }
        },
        position,
        completed
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_completion}
    end
  end
end
