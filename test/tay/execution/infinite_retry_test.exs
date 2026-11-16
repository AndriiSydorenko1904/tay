defmodule Tay.Execution.InfiniteRetryTest do
  use ExUnit.Case, async: true
  alias Tay.{Event, Job}
  alias Tay.Execution.Outcome
  alias Tay.Storage.V2.{Codec, Mutation, Reducer}
  alias Tay.Test.EngineWorker

  defp executing(options) do
    {:ok, intent} = Job.new(EngineWorker, %{}, [worker_key: "worker.v1"] ++ options)
    {:ok, id} = Tay.JobID.decode(intent.id)

    event = %Event{
      record_type: 1,
      data: %{
        "at" => 0,
        "expected_revision" => 0,
        "job_id" => id,
        "definition" => intent.definition,
        "eligible_at" => 0
      }
    }

    {:ok, inserted} = Mutation.from_event(event, nil, 1)
    {:ok, candidate} = Reducer.apply(Reducer.candidate(), inserted)

    started = %Event{
      record_type: 3,
      data: %{
        "at" => 0,
        "expected_revision" => 1,
        "job_id" => id,
        "attempt" => 1,
        "cycle_token" => 1
      }
    }

    {:ok, mutation} = Mutation.from_event(started, candidate.jobs[id], 2)
    {:ok, candidate} = Reducer.apply(candidate, mutation)
    candidate.jobs[id]
  end

  test "infinite retries saturate ordinals without discarding or corrupting snapshots" do
    job = executing(max_attempts: :infinity)
    job = %{job | attempt: 65_535, next_attempt: 65_535}

    for outcome <- [{:failure, 1}, :timeout, :interrupted] do
      assert {:ok, finish} = Outcome.event(job, outcome, 10)
      assert finish.data["disposition"] == 1
      assert finish.data["next_attempt"] == 65_535
      assert finish.data["next_due_at"] == 60_010
      assert {:ok, mutation} = Mutation.from_event(finish, job, 2)
      assert {:ok, next, _} = Reducer.apply_one(job, mutation, 2, %{}, Tay.Event.Value.defaults())
      assert next.state == :retryable
      assert next.revision == job.revision + 1
      assert {:ok, payload} = Codec.encode_snapshot(next)
      assert {:ok, _} = Codec.decode_snapshot(payload)
    end
  end

  test "unavailable tasks remain retryable at a finite limit; ordinary failures still discard" do
    job = executing(max_attempts: 1, availability_key: "api")
    assert {:ok, unavailable} = Outcome.event(job, :unavailable, 10)
    assert unavailable.data["disposition"] == 1
    assert unavailable.data["next_attempt"] == 1
    assert {:ok, mutation} = Mutation.from_event(unavailable, job, 2)
    assert {:ok, next, _} = Reducer.apply_one(job, mutation, 2, %{}, Tay.Event.Value.defaults())
    assert next.state == :retryable
    assert next.diagnostic["code"] == 8
    assert {:ok, failed} = Outcome.event(job, {:failure, 1}, 10)
    assert failed.data["disposition"] == 2

    assert {:error, :invalid_outcome_context} =
             Outcome.event(executing(max_attempts: 1), :unavailable, 10)
  end
end
