defmodule Tay.Execution.OutcomeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Event
  alias Tay.Event.{V1, Value}
  alias Tay.Execution.Outcome
  alias Tay.State.Transition
  alias Tay.Test.EventHelpers, as: H

  defmodule HostileTerm do
    defexception [:payload]
    @impl true
    def message(_), do: raise("raw outcome exception callback was invoked")
  end

  defp step(previous, event, sequence) do
    {:ok, prepared} = Transition.prepare(previous, event)
    {:ok, job} = Transition.apply(prepared, %{sequence: sequence})
    job
  end

  defp started(maximum \\ 2) do
    nil
    |> step(H.inserted(H.definition(%{"scheduled_at" => nil, "max_attempts" => maximum})), 1)
    |> step(H.event(3, 0, 1, %{"attempt" => 1, "cycle_token" => 1}), 2)
  end

  test "classification discards huge/hostile raw terms in constant-size codes" do
    huge = %HostileTerm{payload: :binary.copy(<<255>>, 4_000_000)}
    assert Outcome.returned(:ok) == :success
    assert Outcome.returned({:ok, huge}) == :success
    assert Outcome.returned({:error, huge}) == {:failure, 1}

    for raw <- [huge, "ok", true, nil, {:ok}, {:ok, huge, huge}, {:error, huge, huge}] do
      assert Outcome.returned(raw) == {:failure, 6}
    end

    assert Outcome.caught(:error) == {:failure, 2}
    assert Outcome.caught(:throw) == {:failure, 3}
    assert Outcome.caught(:exit) == {:failure, 4}
  end

  test "success and every failure class produce the exact single schema-1 finish" do
    job = started()
    no_jitter = fn 2 -> <<0::16>> end

    for {normalized, wire, code} <- [
          {:success, 0, nil},
          {{:failure, 1}, 1, 1},
          {{:failure, 2}, 1, 2},
          {{:failure, 3}, 1, 3},
          {{:failure, 4}, 1, 4},
          {{:failure, 6}, 1, 6},
          {:timeout, 2, 5},
          {:interrupted, 3, 7}
        ] do
      assert {:ok, event} = Outcome.event(job, normalized, 11, no_jitter)
      assert event.record_type == 4 and event.payload_schema_version == 1
      assert event.data["outcome"] == wire
      assert event.data["expected_revision"] == job.revision
      assert event.data["execution_token"] == job.execution
      assert event.data["job_id"] == job.id
      assert {:ok, {4, 1, payload}} = Event.encode(event)
      assert {:ok, ^event, _} = Event.decode_payload(4, 1, payload, Value.defaults())
      next = step(job, event, 3)

      if code do
        assert next.state == :retryable
        assert next.eligible_at == 1011
        assert next.diagnostic == %{"code" => code, "version" => 1}
        assert next.next_attempt == if(normalized == :interrupted, do: 1, else: 2)
        assert {:ok, diagnostic} = Value.encode(event.data["diagnostic"])
        assert byte_size(diagnostic) == 44
      else
        assert next.state == :completed
        assert next.completed_at == 11
        assert next.eligible_at == nil and next.next_attempt == nil
        assert next.diagnostic == nil
      end
    end
  end

  test "failure/timeout at M discards without entropy; interruption retains ordinal even at M" do
    job = started(1)
    no_entropy = fn _ -> flunk("terminal outcomes cannot draw jitter") end

    for outcome <- [
          :success,
          {:failure, 1},
          {:failure, 2},
          {:failure, 3},
          {:failure, 4},
          {:failure, 6},
          :timeout
        ] do
      assert {:ok, event} = Outcome.event(job, outcome, 11, no_entropy)
      assert event.data["disposition"] == if(outcome == :success, do: 0, else: 2)
      assert event.data["next_due_at"] == nil and event.data["next_attempt"] == nil
      assert {:ok, _} = Transition.prepare(job, event)
    end

    assert {:ok, interrupted} = Outcome.event(job, :interrupted, 11, fn 2 -> <<250::16>> end)
    assert interrupted.data["next_attempt"] == 1
    assert interrupted.data["next_due_at"] == 1261
    assert {:ok, _} = Transition.prepare(job, interrupted)
  end

  test "invalid producer inputs or entropy failure do not synthesize a worker failure" do
    job = started()
    assert {:error, :invalid_outcome} = Outcome.event(job, {:failure, 5}, 0)

    assert {:error, :invalid_outcome_context} =
             Outcome.event(%{job | state: :available}, :timeout, 0)

    assert {:error, :invalid_outcome_context} = Outcome.event(job, :success, V1.max_time() + 1)

    assert {:error, :invalid_outcome_context} =
             Outcome.event(%{job | execution: nil}, :success, 0)

    assert {:error, :random_source_failed} = Outcome.event(job, :timeout, 0, fn _ -> :failed end)
  end

  property "all generated finish branches pass the unchanged live/replay transition contract" do
    check all(
            maximum <- integer(1..65_535),
            ordinal <- integer(1..maximum),
            at <- one_of([integer(0..V1.max_time()), member_of([0, V1.max_time()])]),
            outcome <-
              member_of([
                :success,
                {:failure, 1},
                {:failure, 2},
                {:failure, 3},
                {:failure, 4},
                {:failure, 6},
                :timeout,
                :interrupted
              ]),
            max_runs: 100
          ) do
      job = %{started(maximum) | attempt: ordinal, next_attempt: ordinal}
      assert {:ok, event} = Outcome.event(job, outcome, at)
      assert {:ok, {4, 1, bytes}} = Event.encode(event)
      assert {:ok, decoded, _} = Event.decode_payload(4, 1, bytes, Value.defaults())
      assert step(job, event, 3) == step(job, decoded, 3)

      cond do
        outcome == :success -> assert event.data["disposition"] == 0
        outcome == :interrupted -> assert event.data["next_attempt"] == ordinal
        ordinal < maximum -> assert event.data["next_attempt"] == ordinal + 1
        true -> assert event.data["disposition"] == 2
      end
    end
  end
end
