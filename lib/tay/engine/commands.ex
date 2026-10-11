defmodule Tay.Engine.Commands do
  @moduledoc false

  alias Tay.{Error, Event, JobID, Queue}
  alias Tay.Engine.{Admission, Persistence, ProjectionState}
  alias Tay.Execution.Clock
  alias Tay.State.{CombinedInspection, InspectionIndex}

  def execute(intent, state, insert_new, cancel_task)

  def execute({:get, raw}, state, _insert_new, _cancel_task) do
    result =
      case ProjectionState.lookup(state, raw) do
        nil -> {:error, :not_found}
        job -> {:ok, ProjectionState.view(state, job)}
      end

    {result, state}
  end

  def execute({:inspect_jobs, query}, state, _insert_new, _cancel_task) do
    page =
      CombinedInspection.page(
        state.projection.inspection,
        state.projection.jobs,
        state.terminal_store,
        query
      )

    {{:ok, %{page | jobs: Enum.map(page.jobs, &ProjectionState.view(state, &1))}}, state}
  end

  def execute(:inspect_stats, state, _insert_new, _cancel_task) do
    stats =
      Map.merge(
        state.terminal_stats.states,
        InspectionIndex.stats(state.projection.inspection),
        fn _state, cold, hot -> cold + hot end
      )

    {{:ok, stats}, state}
  end

  def execute(:inspect_queues, state, _insert_new, _cancel_task) do
    queues =
      state.config.queues
      |> Enum.map(&queue_view(state, &1))
      |> Enum.sort_by(& &1.key)

    {{:ok, queues}, state}
  end

  def execute({:insert, raw, worker, bytes}, state, insert_new, _cancel_task) do
    existing = ProjectionState.lookup(state, raw)

    cond do
      existing && existing.definition_bytes == bytes ->
        {{:ok, ProjectionState.view(state, existing)}, state}

      existing ->
        failure(state, :invalid, :id_conflict, raw)

      state.mode != :ready ->
        failure(state, :unavailable, :draining, raw)

      true ->
        insert_new.(state, raw, worker, bytes)
    end
  end

  def execute({operation, queue}, state, _insert_new, _cancel_task)
      when operation in [:pause_queue, :resume_queue] do
    if Map.has_key?(state.config.queues, queue) do
      paused =
        if operation == :pause_queue,
          do: MapSet.put(state.paused, queue),
          else: MapSet.delete(state.paused, queue)

      next = %{state | paused: paused}
      hook(state.config, {:operations, operation})
      Tay.Telemetry.queue_control(state.config.name, operation, queue)
      {:ok, next}
    else
      {{:error, Error.new(:invalid, :unknown_queue, nil, operation)}, state}
    end
  end

  def execute({operation, raw, revision}, state, _insert_new, cancel_task)
      when operation in [:cancel, :retry] do
    mutate(state, operation, raw, revision, cancel_task)
  end

  def execute(_, state, _insert_new, _cancel_task) do
    {{:error, Error.new(:invalid, :invalid_request)}, state}
  end

  defp queue_view(state, {key, name}) do
    %Queue{
      key: key,
      name: name,
      paused: MapSet.member?(state.paused, key),
      concurrency: Map.fetch!(state.config.queue_limits, key),
      executing: Map.get(state.slots, key, 0),
      jobs:
        InspectionIndex.queue_count(state.projection.inspection, key) +
          (get_in(state.terminal_stats, [:queues, key, :count]) || 0),
      states:
        (get_in(state.terminal_stats, [:queues, key, :states]) || ProjectionState.zero_states())
        |> Map.merge(InspectionIndex.queue_stats(state.projection.inspection, key), fn
          _state, cold, hot -> cold + hot
        end)
    }
  end

  defp mutate(state, operation, raw, revision, cancel_task) do
    job = ProjectionState.lookup(state, raw)

    cond do
      lifecycle_barrier?(state) ->
        mutation_failure(state, operation, raw, revision, :unavailable, :generation_stopping)

      is_nil(job) ->
        {{:error, :not_found}, state}

      revision != ProjectionState.view(state, job).revision ->
        mutation_failure(state, operation, raw, revision, :conflict, :revision_conflict)

      operation == :cancel and job.state == :cancelled ->
        {{:ok, ProjectionState.view(state, job)}, state}

      operation == :cancel and job.state in [:completed, :discarded] ->
        mutation_failure(state, operation, raw, revision, :conflict, :terminal_state)

      operation == :retry and job.state not in [:retryable, :discarded] ->
        mutation_failure(state, operation, raw, revision, :conflict, :state_conflict)

      true ->
        persist_mutation(state, operation, raw, revision, job, cancel_task)
    end
  end

  defp persist_mutation(state, operation, raw, revision, job, cancel_task) do
    event = mutation_event(operation, job, Clock.wall(state.config.clock))

    case Persistence.commit(state, job, event) do
      {:ok, next_job, next} ->
        next = if operation == :cancel, do: cancel_task.(next, raw), else: next
        {{:ok, ProjectionState.view(next, next_job)}, next}

      {:error, reason} ->
        mutation_failure(
          state,
          operation,
          raw,
          revision,
          :capacity,
          bounded_commit_error(reason)
        )
    end
  end

  defp lifecycle_barrier?(%{lifecycle_fenced: nil}), do: false

  defp lifecycle_barrier?(state) do
    token = state.lifecycle_fenced

    with {:ok, meta} <- Admission.metadata(state.config.name),
         true <- meta.generation == state.generation,
         [{:operation, ^token, _, stage, _}] when stage in [:submitted, :closing, :starting] <-
           :ets.lookup(state.config.name, :operation),
         do: true,
         else: (_ -> false)
  end

  defp mutation_event(:cancel, job, at),
    do: event(5, job, at, %{"execution_token" => job.execution})

  defp mutation_event(:retry, job, at) do
    event(6, job, at, %{
      "mode" => if(job.state == :discarded, do: 1, else: 0),
      "new_due_at" => at
    })
  end

  defp mutation_failure(state, operation, raw, revision, kind, reason) do
    {{:error, Error.new(kind, reason, JobID.encode(raw), operation, revision)}, state}
  end

  defp bounded_commit_error({:resource_limit, key}), do: key

  defp bounded_commit_error(reason) when reason in [:sequence_exhausted, :segment_id_exhausted],
    do: reason

  defp bounded_commit_error(_), do: :event_budget

  defp event(type, job, at, fields) do
    %Event{
      record_type: type,
      data:
        Map.merge(%{"job_id" => job.id, "expected_revision" => job.revision, "at" => at}, fields)
    }
  end

  defp failure(state, kind, reason, raw) do
    {{:error, Error.new(kind, reason, JobID.encode(raw), :insert)}, state}
  end

  if Mix.env() == :test do
    defp hook(config, point) do
      if is_function(Map.get(config, :test_hook), 1), do: config.test_hook.(point)
      :ok
    end
  else
    defp hook(_config, _point), do: :ok
  end
end
