defmodule Tay.Engine.Commands do
  @moduledoc false

  alias Tay.{Error, Event, JobID, Queue, Schedule}
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

  def execute({:inspect_schedules, query}, state, _insert_new, _cancel_task) do
    {{:ok, Tay.State.ScheduleIndex.page(state.schedule_index, state.schedules, query)}, state}
  end

  def execute({:get_schedule, id}, state, _, _) do
    case Map.fetch(state.schedules, id) do
      {:ok, schedule} -> {{:ok, Schedule.view(schedule)}, state}
      :error -> {{:error, :not_found}, state}
    end
  end

  def execute({:get_result, raw}, state, _insert_new, _cancel_task) do
    case Map.fetch(state.results, raw) do
      {:ok, result} -> {{:ok, result.value}, state}
      :error -> {:missing, state}
    end
  end

  def execute(
        {:deliver_schedule, id, definition, due, next_at, at, raw, worker, bytes, durability},
        state,
        insert_new,
        cancel_task
      ) do
    case Map.get(state.schedules, id) do
      %{definition: ^definition, cancelled_at: nil, next_at: current} = schedule
      when current > due ->
        {{:ok, Schedule.view(schedule)}, state}

      %{definition: ^definition, cancelled_at: nil, next_at: ^due} = schedule ->
        active_id = Map.get(schedule, :active_job_id)
        active_ids = Enum.uniq(Map.get(schedule, :active_job_ids, []) ++ List.wrap(active_id))

        busy? =
          Enum.any?(active_ids, fn encoded ->
            case JobID.decode(encoded) do
              {:ok, raw_id} ->
                job = ProjectionState.lookup(state, raw_id)

                Map.has_key?(state.executions, raw_id) or
                  (job && not ProjectionState.terminal?(job))

              _ ->
                false
            end
          end) or
            Enum.any?(state.running, fn {_, entry} -> Map.get(entry, :schedule_id) == id end)

        existing = ProjectionState.lookup(state, raw)
        policy = definition["overlap"]

        cond do
          is_nil(existing) and busy? and policy == "queue" ->
            {{:error, Error.new(:unavailable, :schedule_overlap, id, :deliver_schedule)}, state}

          is_nil(existing) and busy? and policy == "skip" ->
            deliver_advance(state, schedule, due, next_at, at, active_id)

          true ->
            worker = Map.get(state.config.workers, definition["task"], worker)

            case execute(
                   {:insert, raw, worker, bytes, durability},
                   state,
                   insert_new,
                   cancel_task
                 ) do
              {{:ok, _}, next} ->
                deliver_advance(next, next.schedules[id], due, next_at, at, JobID.encode(raw))

              failure ->
                failure
            end
        end

      _ ->
        {{:error, Error.new(:conflict, :schedule_changed, id, :deliver_schedule)}, state}
    end
  end

  def execute({:register_schedule, %Schedule{} = schedule}, state, _insert_new, _cancel_task) do
    previous = Map.get(state.schedules, schedule.id)

    cond do
      previous && previous.definition["overlap"] == "allow" && schedule.overlap != "allow" &&
          not Map.get(previous, :membership_complete, false) ->
        {{:error,
          Error.new(:conflict, :schedule_membership_unknown, schedule.id, :register_schedule)},
         state}

      previous && is_nil(previous.cancelled_at) && previous.definition == schedule.definition ->
        {{:ok, Schedule.view(previous)}, state}

      true ->
        revision = if previous, do: previous.revision, else: 0

        event =
          schedule_state_event(schedule.id, revision, schedule.registered_at, %{
            definition: schedule.definition,
            registered_at: schedule.registered_at,
            next_at: schedule.next_at,
            last_at: nil,
            cancelled_at: nil,
            active_job_id: if(previous, do: Map.get(previous, :active_job_id), else: nil),
            active_job_ids: if(previous, do: Map.get(previous, :active_job_ids, []), else: []),
            membership_complete:
              if(previous, do: Map.get(previous, :membership_complete, false), else: true)
          })

        auxiliary_commit(state, event, schedule.id, :register_schedule)
    end
  end

  def execute({:advance_schedule, id, revision, due_at, next_at, at}, state, _, _) do
    case Map.get(state.schedules, id) do
      %{revision: ^revision, next_at: ^due_at, cancelled_at: nil} = schedule
      when next_at > due_at and at >= due_at ->
        next = %{schedule | last_at: due_at, next_at: next_at}
        event = schedule_state_event(id, revision, at, next)
        auxiliary_commit(state, event, id, :advance_schedule)

      _ ->
        {{:error, Error.new(:conflict, :schedule_changed, id, :advance_schedule)}, state}
    end
  end

  def execute({:cancel_schedule, id, revision, at}, state, _, _) do
    case Map.get(state.schedules, id) do
      %{cancelled_at: cancelled_at} = schedule when not is_nil(cancelled_at) ->
        {{:ok, Schedule.view(schedule)}, state}

      %{revision: ^revision} = schedule ->
        event = schedule_state_event(id, revision, at, %{schedule | cancelled_at: at})
        auxiliary_commit(state, event, id, :cancel_schedule)

      _ ->
        {{:error, Error.new(:conflict, :schedule_changed, id, :cancel_schedule)}, state}
    end
  end

  def execute({:insert, raw, worker, bytes, durability}, state, insert_new, _cancel_task) do
    durability = durability || state.config.job_durability
    existing = ProjectionState.lookup(state, raw)
    existing_durability = if(existing, do: ProjectionState.durability(state, existing))

    cond do
      existing && existing.definition_bytes == bytes && existing_durability == durability ->
        {{:ok, ProjectionState.view(state, existing)}, state}

      existing ->
        failure(state, :invalid, :id_conflict, raw)

      state.mode != :ready ->
        failure(state, :unavailable, :draining, raw)

      true ->
        insert_new.(state, raw, worker, bytes, durability)
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
      oldest_ready_age_ms:
        Tay.State.QueueIndex.oldest_age(
          state.projection.ready,
          key,
          Clock.wall(state.config.clock)
        ),
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

  defp schedule_state_event(id, revision, at, schedule) do
    %Event{
      record_type: 13,
      payload_schema_version: 2,
      data: %{
        "at" => at,
        "expected_revision" => revision,
        "revision" => revision + 1,
        "schedule_id" => id,
        "definition" => schedule.definition,
        "registered_at" => schedule.registered_at,
        "next_at" => schedule.next_at,
        "last_at" => schedule.last_at,
        "cancelled_at" => schedule.cancelled_at,
        "active_job_id" => Map.get(schedule, :active_job_id),
        "active_job_ids" => Map.get(schedule, :active_job_ids, []),
        "membership_complete" => Map.get(schedule, :membership_complete, false)
      }
    }
  end

  defp deliver_advance(state, schedule, due, next_at, at, active_id) do
    event = %Event{
      record_type: 11,
      payload_schema_version: 2,
      data: %{
        "at" => at,
        "due_at" => due,
        "next_at" => next_at,
        "expected_revision" => schedule.revision,
        "schedule_id" => schedule.id,
        "active_job_id" => active_id
      }
    }

    auxiliary_commit(state, event, schedule.id, :deliver_schedule)
  end

  defp auxiliary_commit(state, event, id, operation) do
    case Persistence.commit_auxiliary(state, event) do
      {:ok, next} ->
        Tay.Telemetry.schedule_transition(state.config.name, operation, id)
        {{:ok, Schedule.view(next.schedules[id])}, next}

      {:error, {:resource_limit, key}} ->
        {{:error, Error.new(:capacity, key, id, operation)}, state}

      {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
        {{:error, Error.new(:capacity, reason, id, operation)}, state}

      {:error, reason} ->
        {{:error, Error.new(:conflict, reason, id, operation)}, state}
    end
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
