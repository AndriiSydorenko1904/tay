defmodule Tay.Engine.OnlineCheckpoint do
  @moduledoc false

  alias Tay.Engine.CompactionEstimate
  alias Tay.Execution.Clock
  alias Tay.State.{JobIndex, TerminalStore}

  @segment_catalog_limit 128
  @terminal_states [:completed, :cancelled, :discarded]

  def create(state) do
    table =
      :ets.new(Tay.Engine.OnlineSnapshot, [
        :set,
        :protected,
        read_concurrency: true
      ])

    try do
      :ok =
        JobIndex.fold(
          state.projection.jobs,
          fn job, :ok ->
            true = :ets.insert(table, {job.id, job})
            :ok
          end,
          :ok
        )

      :ok =
        TerminalStore.fold(
          state.terminal_store,
          fn job, :ok ->
            true = :ets.insert(table, {job.id, job})
            :ok
          end,
          :ok
        )

      {:ok,
       %{
         table: table,
         frontier: state.next_sequence - 1,
         next_availability_order: state.next_availability_order
       }}
    catch
      kind, reason ->
        delete(table)
        {:error, {:snapshot_capture_failed, {kind, reason}}}
    end
  end

  @spec delete(nil | :ets.table() | %{table: :ets.table()}) :: :ok
  def delete(nil), do: :ok
  def delete(%{table: table}), do: delete(table)

  def delete(table) do
    try do
      :ets.delete(table)
      :ok
    catch
      :error, :badarg -> :ok
    end
  end

  def recovered_config(config, summary) do
    case Map.get(summary, :compaction_terminal_retention) do
      nil -> config
      retention -> put_retention(config, retention)
    end
  end

  def put_retention(config, retention) do
    %{
      config
      | compaction: %{
          config.compaction
          | terminal_retention: Tay.Storage.V2.Retention.persisted(retention)
        }
    }
  end

  def adopt(state, %{recovered: recovered} = stats) do
    jobs = recovered.candidate.jobs
    retained = MapSet.new(Map.keys(jobs))

    TerminalStore.fold(
      state.terminal_store,
      fn job, :ok ->
        if not MapSet.member?(retained, job.id),
          do: :ok = TerminalStore.delete(state.terminal_store, job.id)

        :ok
      end,
      :ok
    )

    terminal_budget = terminal_budget(jobs)

    segment_catalog =
      recovered.store.segments
      |> Enum.map(&Map.take(&1, [:id, :state, :bytes, :count, :first_sequence, :last_sequence]))
      |> Enum.take(-@segment_catalog_limit)

    %{
      state
      | config: put_retention(state.config, stats.terminal_retention),
        epoch_id: recovered.epoch_id,
        next_sequence: recovered.next_sequence,
        next_availability_order: recovered.candidate.next_availability_order,
        segment: Map.take(recovered.highest, [:id, :bytes, :count, :state]),
        segment_catalog: segment_catalog,
        history_bytes: recovered.total_segment_bytes,
        segment_count: recovered.segment_count,
        active_budget: state.active_budget,
        terminal_budget: terminal_budget,
        budget: state.budget,
        terminal_stats: terminal_statistics(jobs),
        definition_bytes:
          Enum.reduce(jobs, 0, fn {_id, job}, total ->
            total + byte_size(job.definition_bytes)
          end),
        compaction_estimate:
          Enum.reduce(jobs, CompactionEstimate.new(), fn {_id, job}, estimate ->
            CompactionEstimate.replace(estimate, nil, job)
          end),
        events_since_checkpoint: recovered.next_sequence - recovered.manifest.tail_first_sequence,
        last_compaction_at: max(stats.captured_at, Clock.wall(state.config.clock)),
        online_compaction: nil
    }
  end

  def adopt_rotation(
        state,
        %{
          previous: previous,
          segment: %{id: id, state: :active, bytes: 44, count: 0} = segment,
          next_sequence: next_sequence
        }
      ) do
    current = Map.take(state.segment, [:id, :state, :bytes, :count])

    cond do
      previous != current ->
        {:error, :previous_segment}

      next_sequence != state.next_sequence ->
        {:error, :next_sequence}

      id == state.segment.id ->
        {:ok, state}

      id != state.segment.id + 1 ->
        {:error, :segment_id}

      true ->
        {:ok, rotate(state, segment, id)}
    end
  end

  def adopt_rotation(_state, _rotation), do: {:error, :shape}

  defp rotate(state, segment, id) do
    sealed =
      state.segment_catalog
      |> List.last()
      |> Map.merge(%{
        state: :sealed,
        bytes: state.segment.bytes + if(state.segment.state == :active, do: 64, else: 0)
      })

    active = %{
      id: id,
      state: :active,
      bytes: 44,
      count: 0,
      first_sequence: state.next_sequence,
      last_sequence: nil
    }

    catalog =
      state.segment_catalog
      |> List.replace_at(-1, sealed)
      |> Kernel.++([active])
      |> Enum.take(-@segment_catalog_limit)

    added = 44 + if(state.segment.state == :active, do: 64, else: 0)

    %{
      state
      | segment: segment,
        segment_catalog: catalog,
        segment_count: state.segment_count + 1,
        history_bytes: state.history_bytes + added
    }
  end

  defp terminal_budget(jobs) do
    Enum.reduce(jobs, %{count: 0, bytes: 0}, fn {_id, job}, budget ->
      if terminal?(job), do: add_charge(budget, job), else: budget
    end)
  end

  defp terminal_statistics(jobs) do
    Enum.reduce(jobs, empty_terminal_stats(), fn {_id, job}, stats ->
      if terminal?(job), do: update_terminal_stats(stats, job), else: stats
    end)
  end

  defp update_terminal_stats(stats, job) do
    queue = job.definition["queue_key"]
    queue_stats = Map.get(stats.queues, queue, %{count: 0, states: zero_states()})

    %{
      states: Map.update!(stats.states, job.state, &(&1 + 1)),
      queues:
        Map.put(stats.queues, queue, %{
          count: queue_stats.count + 1,
          states: Map.update!(queue_stats.states, job.state, &(&1 + 1))
        })
    }
  end

  defp add_charge(budget, job),
    do: %{count: budget.count + 1, bytes: budget.bytes + job.charge.bytes}

  defp empty_terminal_stats, do: %{states: zero_states(), queues: %{}}

  defp zero_states,
    do: Map.new(@terminal_states ++ [:available, :scheduled, :executing, :retryable], &{&1, 0})

  defp terminal?(%{state: state}), do: state in @terminal_states
end
