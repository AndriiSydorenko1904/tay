defmodule Tay.State.ProjectionTest do
  use ExUnit.Case, async: true
  alias Tay.State.{Transition, Projection, JobIndex, QueueIndex, SchedulerIndex}
  alias Tay.Test.EventHelpers, as: H

  test "all six lifecycle effects maintain exact private indexes" do
    projection = Projection.new(%{"w" => __MODULE__}, %{"q" => :q})

    Enum.with_index(~w(E1 E2 E3 E4 E6 E5), 1)
    |> Enum.reduce(nil, fn {id, seq}, previous ->
      {:ok, effect} = Transition.prepare(previous, H.expected(id))
      {:ok, job} = Transition.apply(effect, %{sequence: seq})
      assert :ok = Projection.replace(projection, previous, job)
      assert JobIndex.get(projection.jobs, job.id) == job
      assert Projection.valid?(projection)

      assert QueueIndex.ready(projection.queue, "q", 10_000, 5) ==
               if(job.state == :available, do: [job.id], else: [])

      assert SchedulerIndex.due(projection.schedule, 10_000, 5) ==
               if(job.state in [:scheduled, :retryable], do: [job.id], else: [])

      job
    end)

    for table <- [projection.jobs, projection.queue, projection.schedule] do
      assert :ets.info(table, :protection) == :private
      assert :ets.info(table, :named_table) == false

      assert Task.async(fn -> assert_raise ArgumentError, fn -> :ets.tab2list(table) end end)
             |> Task.await()
    end
  end

  test "ready lookup is bounded and unmapped jobs do not obstruct eligible IDs" do
    p = Projection.new(%{"w" => __MODULE__}, %{"q" => :q})

    for n <- 1..100 do
      definition =
        H.definition(%{
          "scheduled_at" => nil,
          "worker_key" => if(n <= 50, do: "missing", else: "w")
        })

      {:ok, e} = Transition.prepare(nil, H.inserted(definition, 0, H.id(n)))
      {:ok, job} = Transition.apply(e, %{sequence: n})
      Projection.replace(p, nil, job)
    end

    assert QueueIndex.ready(p.queue, "q", 0, 2) == [H.id(51), H.id(52)]
    assert QueueIndex.ready(p.queue, "absent", 0, 2) == []
    assert QueueIndex.ready(p.queue, "q", -1, 2) == []
    assert JobIndex.count(p.jobs) == 100
    assert Projection.valid?(p)
  end
end
