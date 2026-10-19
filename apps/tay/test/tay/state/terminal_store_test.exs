defmodule Tay.State.TerminalStoreTest do
  use ExUnit.Case, async: false

  alias Tay.State.{CombinedInspection, InspectionIndex, JobIndex, TerminalStore}

  @registry __MODULE__

  setup do
    registry = :ets.new(@registry, [:named_table, :set, :public])
    directory = Path.join(System.tmp_dir!(), "tay-terminal-index-#{System.unique_integer()}")
    path = Path.join(directory, "store")

    on_exit(fn ->
      File.rm_rf!(directory)
      if :ets.info(registry) != :undefined, do: :ets.delete(registry)
    end)

    %{path: path}
  end

  test "pages across hot and terminal jobs without loading terminal history into the hot index",
       %{path: path} do
    terminal = Map.new(for n <- [1, 3, 5, 7], do: {id(n), job(n, :completed)})
    {:ok, store} = TerminalStore.open(@registry, path, terminal)
    jobs = JobIndex.new()
    inspection = InspectionIndex.new()

    for n <- [2, 4, 6, 8] do
      current = job(n, :available)
      true = JobIndex.put(jobs, current)
      :ok = InspectionIndex.replace(inspection, nil, current)
    end

    query = query(limit: 3)
    first = CombinedInspection.page(inspection, jobs, store, query)
    assert Enum.map(first.jobs, & &1.inserted_at) == [8, 7, 6]
    assert first.total_count == 8

    second = CombinedInspection.page(inspection, jobs, store, %{query | position: first.next_key})
    assert Enum.map(second.jobs, & &1.inserted_at) == [5, 4, 3]

    previous =
      CombinedInspection.page(inspection, jobs, store, %{query | position: second.previous_key})

    assert Enum.map(previous.jobs, & &1.inserted_at) == [8, 7, 6]

    last = CombinedInspection.page(inspection, jobs, store, %{query | position: :last})
    assert Enum.map(last.jobs, & &1.inserted_at) == [2, 1]
    assert last.next_key == nil

    assert :ok = TerminalStore.close(store)
  end

  test "uses compact metadata for terminal filters and keeps it current", %{path: path} do
    terminal = Map.new(for n <- 1..5, do: {id(n), job(n, :completed)})
    {:ok, store} = TerminalStore.open(@registry, path, terminal)

    assert %{jobs: jobs, total_count: 3} =
             TerminalStore.candidates(store, query(worker_contains: "odd"))

    assert Enum.map(jobs, & &1.inserted_at) == [5, 3, 1]

    assert :ok = TerminalStore.delete(store, id(3))
    assert :ok = TerminalStore.put(store, job(6, :cancelled))

    assert %{jobs: jobs, total_count: 2} =
             TerminalStore.candidates(store, query(worker_contains: "odd"))

    assert Enum.map(jobs, & &1.inserted_at) == [5, 1]
    assert :ok = TerminalStore.close(store)
  end

  defp query(options) do
    %{
      id: nil,
      states: nil,
      queues: nil,
      workers: nil,
      worker_contains: Keyword.get(options, :worker_contains),
      limit: Keyword.get(options, :limit, 50),
      position: nil
    }
  end

  defp job(n, state) do
    %{
      id: id(n),
      inserted_at: n,
      state: state,
      definition: %{
        "queue_key" => "default",
        "worker_key" => if(rem(n, 2) == 0, do: "even.v1", else: "odd.v1")
      }
    }
  end

  defp id(n), do: <<n::128>>
end
