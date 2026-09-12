defmodule Tay.Engine.JobBuilderTest do
  use ExUnit.Case, async: true
  alias Tay.{Job, JobID}

  defmodule Worker do
    use Tay.Worker, key: "stable.worker", queue: :q, max_attempts: 3
    @impl true
    def perform(_), do: raise("Phase 4 must never execute")
  end

  test "builder creates stable immutable definition, but never a durable/available job" do
    assert {:ok, job} = Worker.new(%{"x" => 1})
    assert {:ok, id} = JobID.decode(job.id)
    assert byte_size(id) == 16
    assert job.id == JobID.encode(id)
    assert job.state == nil
    assert job.inserted_at == nil
    assert job.definition["worker_key"] == "stable.worker"
    assert job.definition["max_attempts"] == 3
    assert job.definition["timeout_ms"] == 30_000
    assert {:ok, same} = Worker.new(%{"x" => 1}, id: job.id)
    assert same.definition == job.definition
    assert {:ok, other} = Worker.new(%{"x" => 1})
    refute other.id == job.id
  end

  test "explicit bare worker metadata, UTC schedule, and invalid inputs" do
    dt = ~U[2026-09-12 00:00:00.000Z]
    assert {:ok, job} = Job.new(__MODULE__, %{}, worker_key: "bare", scheduled_at: dt)
    assert job.definition["scheduled_at"] == DateTime.to_unix(dt, :millisecond)

    for opts <- [
          [unknown: 1],
          [max_attempts: 0],
          [id: String.duplicate("0", 32)],
          [timeout_ms: :infinity],
          [queue: nil],
          [scheduled_at: -1],
          [max_attempts: 1, max_attempts: 2]
        ] do
      assert {:error, _} = Worker.new(%{}, opts)
    end

    assert {:error, _} = Worker.new(%{"pid" => self()})
    assert {:error, _} = Worker.new(%Tay.Job{})
    assert {:error, _} = Job.new(__MODULE__, %{})
    assert {:error, _} = Worker.new(%{}, scheduled_at: %{dt | year: :invalid})
    assert {:error, _} = JobID.decode(String.duplicate("A", 32))
  end
end
