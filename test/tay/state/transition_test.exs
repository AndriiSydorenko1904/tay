defmodule Tay.State.TransitionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Event
  alias Tay.Event.{Value, V1}
  alias Tay.State.Transition, as: T
  alias Tay.Storage.Record
  alias Tay.Test.EventHelpers, as: H

  defp step(p, event, seq) do
    {:ok, prepared} = T.prepare(p, event)
    {:ok, job} = T.apply(prepared, %{sequence: seq})
    job
  end

  test "approved six-record history is pure and has precisely the expected transitions" do
    {job, states} =
      Enum.with_index(~w(E1 E2 E3 E4 E6 E5), 1)
      |> Enum.reduce({nil, []}, fn {id, seq}, {p, states} ->
        next = step(p, H.expected(id), seq)
        {next, states ++ [next.state]}
      end)

    assert states == [:scheduled, :available, :executing, :retryable, :available, :cancelled]
    assert job.revision == 6
    assert job.attempt == 1
    assert job.cycle == 1
    assert job.next_attempt == nil
    assert job.execution == nil
    assert job.definition == H.definition()
    assert job.diagnostic == %{"code" => 1, "version" => 1}
    assert {:ok, bytes} = Value.encode(job.definition)
    assert job.definition_bytes == bytes
  end

  test "attempt/state/revision/execution mismatches are rejected without applying" do
    p = step(nil, H.expected("E1"), 1) |> step(H.expected("E2"), 2)
    {:ok, bad, _} = Record.decode(H.fixture("N7"))
    {:ok, event, _} = Event.decode_payload(3, 1, bad.payload, Value.defaults())
    assert {:error, :invalid_transition} = T.prepare(p, event)

    for field <- ["expected_revision", "cycle_token", "attempt"] do
      event = H.expected("E3")

      assert {:error, _} =
               T.prepare(p, %{event | data: Map.update!(event.data, field, &(&1 + 1))})
    end

    assert {:error, _} = T.prepare(p, H.expected("E1"))
    assert {:error, _} = T.prepare(nil, H.expected("E3"))
    {:ok, prepared} = T.prepare(p, H.expected("E3"))
    assert {:error, :invalid_position} = T.apply(prepared, %{sequence: 2})
  end

  defp started(max_attempts \\ 1) do
    p =
      step(
        nil,
        H.inserted(H.definition(%{"scheduled_at" => nil, "max_attempts" => max_attempts})),
        1
      )

    step(p, H.event(3, 0, 1, %{"attempt" => 1, "cycle_token" => 1}), 2)
  end

  defp finished(p, outcome, code, disposition, next, due, at \\ 0),
    do:
      H.event(4, at, p.revision, %{
        "execution_token" => p.execution,
        "outcome" => outcome,
        "diagnostic" => if(code, do: %{"code" => code, "version" => 1}, else: nil),
        "disposition" => disposition,
        "next_attempt" => next,
        "next_due_at" => due
      })

  test "actual failures/timeout exhaust, but interruptions at max reuse ordinal and fresh tokens" do
    p = started()

    for {outcome, code} <- [{1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 6}, {2, 5}] do
      discarded = step(p, finished(p, outcome, code, 2, nil, nil), 3)
      assert discarded.state == :discarded
      retried = step(discarded, H.event(6, 0, 3, %{"mode" => 1, "new_due_at" => 0}), 4)
      assert {retried.attempt, retried.next_attempt, retried.cycle} == {0, 1, 4}
    end

    interrupted = step(p, finished(p, 3, 7, 1, 1, 1000), 3)
    ready = step(interrupted, H.event(2, 1000, 3, %{"due_at" => 1000}), 4)
    again = step(ready, H.event(3, 1000, 4, %{"attempt" => 1, "cycle_token" => 1}), 5)
    assert {again.attempt, again.execution, again.cycle} == {1, 5, 1}
    assert {:error, _} = T.prepare(again, finished(p, 0, nil, 0, nil, nil))
    complete = step(again, finished(again, 0, nil, 0, nil, nil, 999), 6)
    assert complete.completed_at == 999
    assert complete.state == :completed
    assert complete.diagnostic["code"] == 7

    assert {:error, _} =
             T.prepare(complete, H.event(6, 1000, 6, %{"mode" => 1, "new_due_at" => 1000}))
  end

  test "executing cancellation requires its exact token and fences all later outcomes" do
    p = started()
    assert {:error, _} = T.prepare(p, H.event(5, 0, 2, %{"execution_token" => nil}))
    cancelled = step(p, H.event(5, 0, 2, %{"execution_token" => 2}), 3)
    assert {:error, _} = T.prepare(cancelled, H.event(5, 0, 3, %{"execution_token" => nil}))

    assert {:error, _} =
             T.prepare(cancelled, %{
               finished(p, 0, nil, 0, nil, nil)
               | data: Map.put(finished(p, 0, nil, 0, nil, nil).data, "expected_revision", 3)
             })
  end

  test "candidate refuses retained budgets without publishing partial results" do
    for {key, value, reason} <- [
          {:max_jobs, 0, :retained_jobs},
          {:max_bytes, 1, :retained_bytes},
          {:max_nodes, 1, :retained_nodes}
        ] do
      initial = T.candidate(%{key => value})

      assert {:error, {:resource_limit, ^reason}} =
               T.reduce(H.expected("E1"), %{sequence: 1}, initial)

      assert initial.jobs == %{}
    end

    assert {:ok, candidate} = T.reduce(H.expected("E1"), %{sequence: 1}, T.candidate())
    assert map_size(candidate.jobs) == 1
    assert candidate.bytes > 404
  end

  property "live effects and encoded/decoded pure reconstruction are identical" do
    check all(
            count <- integer(1..50),
            args <- map_of(string(:alphanumeric, max_length: 8), integer(), max_length: 8),
            max_runs: 100
          ) do
      {live, replay} =
        Enum.reduce(1..count, {%{}, T.candidate()}, fn seq, {live, replay} ->
          event = H.inserted(H.definition(%{"args" => args}), 0, H.id(seq))
          job = step(nil, event, seq)
          {:ok, {1, 1, payload}} = Event.encode(event)
          {:ok, decoded, _} = Event.decode_payload(1, 1, payload, Value.defaults())
          {:ok, replay} = T.reduce(decoded, %{sequence: seq}, replay)
          {Map.put(live, job.id, job), replay}
        end)

      assert live == Map.new(replay.jobs, fn {id, job} -> {id, Map.delete(job, :charge)} end)
    end
  end

  property "retry math clamps safely at time ceiling without giant exponentiation" do
    check all(
            attempt <- integer(1..65_535),
            at <- member_of([0, 1, V1.max_time() - 1, V1.max_time()]),
            max_runs: 100
          ) do
      {low, high} = V1.retry_interval(at, attempt)
      expected = min(60_000, 1000 * Integer.pow(2, min(attempt - 1, 6)))
      assert low == min(V1.max_time(), at + expected)
      assert at <= low and low <= high and high <= V1.max_time()
    end
  end
end
