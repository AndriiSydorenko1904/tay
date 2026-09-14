defmodule Tay.Storage.V2PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tay.Event.V1
  alias Tay.Storage.V2.{Codec, Reducer, Snapshot}

  property "snapshot replay equals the remaining mutation history at every frontier" do
    check all(
            id_number <- integer(1..100_000),
            failures <- integer(0..2),
            start_at <- integer(0..100_000),
            max_runs: 80
          ) do
      id = <<id_number::128>>
      history = history(id, failures, start_at)

      Enum.each(0..length(history), fn split ->
        {before, after_frontier} = Enum.split(history, split)
        {:ok, source} = replay(before)
        {:ok, bytes, %{expired_jobs: 0}} = Snapshot.plan(source.jobs)
        {:ok, restored} = restore(bytes)
        assert Snapshot.equivalent?(restored.jobs, source.jobs)

        {:ok, direct} = continue(source, after_frontier)
        {:ok, compacted} = continue(restored, after_frontier, true)
        assert Snapshot.equivalent?(compacted.jobs, direct.jobs)

        {:ok, second, _} = Snapshot.plan(compacted.jobs)
        {:ok, twice} = restore(second)
        assert Snapshot.equivalent?(twice.jobs, compacted.jobs)
      end)
    end
  end

  property "global availability order preserves equal-due FIFO across two snapshots" do
    check all(
            count <- integer(2..40),
            scheduled <- integer(0..count),
            base <- integer(1..100_000),
            max_runs: 80
          ) do
      due = 100
      immediate = count - scheduled

      {:ok, inserted} =
        Enum.reduce(1..count, {:ok, Reducer.candidate()}, fn index, {:ok, candidate} ->
          id = <<base + count + 1 - index::128>>
          definition = definition(3)

          {at, eligible, order, definition} =
            if index <= immediate,
              do: {due, due, index, definition},
              else: {10, due, nil, Map.put(definition, "scheduled_at", due)}

          Reducer.apply(
            candidate,
            mutation(id, :inserted, 0, at, %{
              "definition" => definition,
              "eligible_at" => eligible,
              "availability_order" => order
            })
          )
        end)

      {:ok, source} =
        Enum.reduce((immediate + 1)..count//1, {:ok, inserted}, fn index, {:ok, candidate} ->
          id = <<base + count + 1 - index::128>>

          Reducer.apply(
            candidate,
            mutation(id, :available, 1, due, %{
              "due_at" => due,
              "availability_order" => index
            })
          )
        end)

      expected = Enum.map(1..count, fn index -> <<base + count + 1 - index::128>> end)
      assert queue_ids(source.jobs) == expected
      {:ok, first, _} = Snapshot.plan(source.jobs)
      {:ok, once} = restore(first)
      assert queue_ids(once.jobs) == expected
      {:ok, second, _} = Snapshot.plan(once.jobs)
      assert second == first
      {:ok, twice} = restore(second)
      assert queue_ids(twice.jobs) == expected

      next_id = <<base + count + 1::128>>

      assert {:ok, later} =
               Reducer.apply(
                 twice,
                 mutation(next_id, :inserted, 0, due, %{
                   "definition" => definition(3),
                   "eligible_at" => due,
                   "availability_order" => count + 1
                 })
               )

      assert queue_ids(later.jobs) == expected ++ [next_id]
    end
  end

  property "cycle and execution tokens cannot revive after admin retry and compaction" do
    check all(id_number <- integer(1..100_000), at <- integer(1..100_000), max_runs: 80) do
      id = <<id_number::128>>

      {:ok, inserted} =
        Reducer.apply(
          Reducer.candidate(),
          mutation(id, :inserted, 0, at, %{
            "definition" => definition(1),
            "eligible_at" => at,
            "availability_order" => 1
          })
        )

      {:ok, started} =
        Reducer.apply(
          inserted,
          mutation(id, :started, 1, at, %{"attempt" => 1, "cycle_token" => 1})
        )

      {:ok, discarded} =
        Reducer.apply(
          started,
          mutation(id, :finished, 2, at + 1, %{
            "outcome" => 1,
            "disposition" => 2,
            "execution_token" => 2,
            "next_attempt" => nil,
            "next_due_at" => nil,
            "diagnostic" => %{"version" => 1, "code" => 1}
          })
        )

      assert discarded.jobs[id].terminal_at == at + 1
      {:ok, payloads, _} = Snapshot.plan(discarded.jobs)
      {:ok, compacted} = restore(payloads)

      {:ok, reset} =
        Reducer.apply(
          compacted,
          mutation(id, :retried, 3, at + 2, %{
            "mode" => 1,
            "new_due_at" => at + 2,
            "availability_order" => 1
          })
        )

      assert reset.jobs[id].cycle == 4
      assert reset.jobs[id].terminal_at == nil

      assert {:error, _} =
               Reducer.apply(
                 reset,
                 mutation(id, :started, 4, at + 2, %{"attempt" => 1, "cycle_token" => 1})
               )

      {:ok, restarted} =
        Reducer.apply(
          reset,
          mutation(id, :started, 4, at + 2, %{"attempt" => 1, "cycle_token" => 4})
        )

      interrupted_at = at + 3
      {due, _} = V1.retry_interval(interrupted_at, 1)

      {:ok, interrupted} =
        Reducer.apply(
          restarted,
          mutation(id, :finished, 5, interrupted_at, %{
            "outcome" => 3,
            "disposition" => 1,
            "execution_token" => 5,
            "next_attempt" => 1,
            "next_due_at" => due,
            "diagnostic" => %{"version" => 1, "code" => 7}
          })
        )

      {:ok, payloads, _} = Snapshot.plan(interrupted.jobs)
      {:ok, compacted_again} = restore(payloads)

      {:ok, available} =
        Reducer.apply(
          compacted_again,
          mutation(id, :available, 6, due, %{"due_at" => due, "availability_order" => 1})
        )

      assert {:error, _} =
               Reducer.apply(
                 available,
                 mutation(id, :started, 7, due, %{"attempt" => 1, "cycle_token" => 1})
               )

      {:ok, executing} =
        Reducer.apply(
          available,
          mutation(id, :started, 7, due, %{"attempt" => 1, "cycle_token" => 4})
        )

      assert executing.jobs[id].execution == 8

      assert {:error, _} =
               Reducer.apply(
                 executing,
                 mutation(id, :cancelled, 8, due + 1, %{"execution_token" => 5})
               )

      {:ok, cancelled} =
        Reducer.apply(executing, mutation(id, :cancelled, 8, due + 1, %{"execution_token" => 8}))

      assert cancelled.jobs[id].terminal_at == due + 1
      assert cancelled.jobs[id].execution == nil
    end
  end

  defp history(id, failures, start_at) do
    definition = definition(3)

    insert =
      mutation(id, :inserted, 0, start_at, %{
        "definition" => definition,
        "eligible_at" => start_at,
        "availability_order" => 1
      })

    {events, revision, due} =
      Enum.reduce(1..failures//1, {[insert], 1, start_at}, fn attempt, {events, revision, due} ->
        start = mutation(id, :started, revision, due, %{"attempt" => attempt, "cycle_token" => 1})
        finished_at = due + 1
        next_due = elem(V1.retry_interval(finished_at, attempt), 0)

        finish =
          mutation(id, :finished, revision + 1, finished_at, %{
            "outcome" => 1,
            "disposition" => 1,
            "execution_token" => revision + 1,
            "next_attempt" => attempt + 1,
            "next_due_at" => next_due,
            "diagnostic" => %{"version" => 1, "code" => 1}
          })

        available =
          mutation(id, :available, revision + 2, next_due, %{
            "due_at" => next_due,
            "availability_order" => attempt + 1
          })

        {events ++ [start, finish, available], revision + 3, next_due}
      end)

    start =
      mutation(id, :started, revision, due, %{"attempt" => failures + 1, "cycle_token" => 1})

    finish =
      mutation(id, :finished, revision + 1, due + 1, %{
        "outcome" => 0,
        "disposition" => 0,
        "execution_token" => revision + 1,
        "next_attempt" => nil,
        "next_due_at" => nil,
        "diagnostic" => nil
      })

    events ++ [start, finish]
  end

  defp mutation(id, kind, expected, at, body) do
    %{
      job_id: id,
      kind: kind,
      expected_revision: expected,
      new_revision: expected + 1,
      at: at,
      body: body
    }
  end

  defp definition(max_attempts) do
    %{
      "args" => %{"n" => 1},
      "definition_version" => 1,
      "max_attempts" => max_attempts,
      "queue_key" => "default",
      "retry_policy" => V1.policy(),
      "scheduled_at" => nil,
      "timeout_ms" => 1_000,
      "worker_key" => "worker"
    }
  end

  defp queue_ids(jobs) do
    jobs
    |> Enum.filter(fn {_, job} -> job.state == :available end)
    |> Enum.sort_by(fn {id, job} ->
      {job.definition["queue_key"], job.eligible_at, job.availability_order, id}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp replay(mutations), do: continue(Reducer.candidate(), mutations)

  defp continue(candidate, mutations, rebase? \\ false) do
    Enum.reduce_while(mutations, {:ok, candidate}, fn mutation, {:ok, current} ->
      mutation =
        if rebase? and Map.has_key?(mutation.body, "availability_order") and
             not is_nil(mutation.body["availability_order"]),
           do: put_in(mutation.body["availability_order"], current.next_availability_order),
           else: mutation

      case Reducer.apply(current, mutation) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp restore(payloads) do
    Enum.reduce_while(payloads, {:ok, Reducer.candidate()}, fn payload, {:ok, current} ->
      with {:ok, job} <- Codec.decode_snapshot(payload),
           {:ok, next} <- Reducer.insert_snapshot(current, job) do
        {:cont, {:ok, next}}
      else
        error -> {:halt, error}
      end
    end)
  end
end
