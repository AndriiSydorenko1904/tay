defmodule Tay.Engine.ProjectionState do
  @moduledoc false

  alias Tay.{Job, Storage}
  alias Tay.State.{JobIndex, Projection, TerminalStore, Transition}

  @states [:available, :scheduled, :executing, :retryable, :completed, :cancelled, :discarded]
  @terminal_states [:completed, :cancelled, :discarded]

  def lookup(state, id) do
    JobIndex.get(state.projection.jobs, id) || TerminalStore.get(state.terminal_store, id)
  end

  def account_active(state, previous, job) do
    hot_previous = previous && JobIndex.get(state.projection.jobs, previous.id)

    with {:ok, charged, budget} <- Transition.account(state.budget, hot_previous, job) do
      budget = if terminal?(charged), do: add_charge(budget, charged, -1), else: budget
      {:ok, charged, budget}
    end
  end

  def publish(state, previous, job) do
    hot_previous = previous && JobIndex.get(state.projection.jobs, previous.id)

    cond do
      terminal?(job) ->
        if hot_previous, do: :ok = Projection.delete(state.projection, hot_previous)
        :ok = TerminalStore.put(state.terminal_store, job)

      hot_previous ->
        :ok = Projection.replace(state.projection, hot_previous, job)

      true ->
        if previous, do: :ok = TerminalStore.delete(state.terminal_store, previous.id)
        :ok = Projection.replace(state.projection, nil, job)
    end
  end

  def terminal_statistics(jobs) do
    Enum.reduce(jobs, empty_terminal_stats(), fn {_id, job}, stats ->
      if terminal?(job), do: update_terminal_stats(stats, job, 1), else: stats
    end)
  end

  def replace_terminal_stats(stats, previous, job) do
    stats = if terminal?(previous), do: update_terminal_stats(stats, previous, -1), else: stats
    if terminal?(job), do: update_terminal_stats(stats, job, 1), else: stats
  end

  def zero_states, do: Map.new(@states, &{&1, 0})

  def view(state, job) do
    Job.view(
      job,
      state.config.workers,
      state.config.queues,
      state.store_id,
      state.generation,
      state.epoch_id
    )
  end

  def snapshot(state) do
    %{
      state: state.mode,
      paused_queues: state.paused |> MapSet.to_list() |> Enum.sort(),
      jobs: state.active_budget.count + state.terminal_budget.count,
      active_jobs: state.active_budget.count,
      terminal_jobs: state.terminal_budget.count,
      blocked_jobs: state.blocked,
      state_bytes_charged: state.active_budget.bytes + state.terminal_budget.bytes,
      active_state_bytes_charged: state.active_budget.bytes,
      terminal_state_bytes_charged: state.terminal_budget.bytes,
      max_state_bytes: state.config.max_state_bytes,
      startup_state_bytes_budget: 3 * state.config.max_state_bytes,
      running_executions: map_size(state.running),
      unsettled_executions: state.settlement_reserve,
      queue_slots_used: state.slots,
      execution_outcome_slots: Enum.sum(Map.values(state.config.queue_limits)),
      execution_control_slots: map_size(state.config.queue_limits) + 1,
      canonical_history_bytes: state.history_bytes,
      segment_count: state.segment_count,
      storage_segments: state.segment_catalog,
      storage_segments_truncated: state.segment_count > length(state.segment_catalog),
      compaction_terminal_retention: state.config.compaction.terminal_retention,
      retained_definition_bytes: state.definition_bytes,
      reserved_outcome_bytes: outcome_reserve(state.settlement_reserve),
      remaining_sequence_coordinates: max(Storage.Segment.max_id() - state.next_sequence + 1, 0),
      remaining_segment_coordinates: Storage.Segment.max_id() - state.segment.id,
      max_history_bytes: state.config.max_history_bytes,
      max_segments: state.config.max_segments,
      insertion_space:
        if(state.next_sequence > Storage.Segment.max_id(), do: :exhausted, else: :available)
    }
  end

  def partition_budgets(jobs) do
    Enum.reduce(jobs, {empty_budget(), empty_budget()}, fn {_, job}, {active, terminal} ->
      if terminal?(job) do
        {active, add_charge(terminal, job, 1)}
      else
        {add_charge(active, job, 1), terminal}
      end
    end)
  end

  def replace_partition(budget, previous, job, kind) do
    budget =
      if previous && partition(previous) == kind,
        do: add_charge(budget, previous, -1),
        else: budget

    if partition(job) == kind, do: add_charge(budget, job, 1), else: budget
  end

  def terminal?(nil), do: false
  def terminal?(%{state: state}), do: state in @terminal_states

  def ensure_active_accounting!(state) do
    active = state.active_budget
    budget = state.budget

    if active.count >= 0 and active.bytes >= 0 and
         (active.count > 0 or active.bytes == 0) and
         active.count == budget.count and active.bytes == budget.bytes do
      state
    else
      exit(:invalid_active_memory_accounting)
    end
  end

  defp update_terminal_stats(stats, job, amount) do
    queue = job.definition["queue_key"]
    queue_stats = Map.get(stats.queues, queue, %{count: 0, states: zero_states()})

    %{
      states: Map.update!(stats.states, job.state, &(&1 + amount)),
      queues:
        Map.put(stats.queues, queue, %{
          count: queue_stats.count + amount,
          states: Map.update!(queue_stats.states, job.state, &(&1 + amount))
        })
    }
  end

  defp empty_terminal_stats, do: %{states: zero_states(), queues: %{}}
  defp partition(job), do: if(terminal?(job), do: :terminal, else: :active)
  defp empty_budget, do: %{count: 0, bytes: 0}

  defp add_charge(budget, job, sign) do
    Map.merge(budget, %{
      count: budget.count + sign,
      bytes: budget.bytes + sign * job.charge.bytes
    })
  end

  # A fixed conservative operational reservation, not a persisted format limit.
  defp outcome_reserve(count), do: count * (1_024 + 64 + 44)
end
