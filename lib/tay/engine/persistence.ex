defmodule Tay.Engine.Persistence do
  @moduledoc false

  alias Tay.Event
  alias Tay.Engine.{CompactionEstimate, OnlineCheckpoint, ProjectionState}
  alias Tay.Execution.LocalFence
  alias Tay.State.Transition
  alias Tay.State.Auxiliary
  alias Tay.Storage.{Segment, Writer}
  alias Tay.Storage.V2.{Codec, Mutation}
  alias Tay.Storage.V2.Reducer, as: V2Reducer

  @memory_reclaim_idle_ms 1_000
  @segment_catalog_limit 128

  def commit(state, previous, event, encoded \\ nil) do
    {durability, _encoded} =
      case encoded do
        {:durability, mode, payload} when mode in [:persistent, :volatile] -> {mode, payload}
        payload -> {nil, payload}
      end

    mode =
      durability ||
        if(previous, do: ProjectionState.durability(state, previous), else: :persistent)

    case mode do
      :volatile -> commit_volatile(state, previous, event)
      :persistent -> commit_v2(state, previous, event)
    end
  end

  def commit_auxiliary(state, event, job \\ nil) do
    if job && ProjectionState.durability(state, job) == :volatile,
      do: commit_volatile_auxiliary(state, event, job),
      else: commit_persistent_auxiliary(state, event, job)
  end

  defp commit_persistent_auxiliary(state, event, job) do
    ensure_generation_live!(state)

    seed = auxiliary_seed(state, event, job)

    with {:ok, {type, 2, payload}} <-
           Event.encode(
             event,
             state.config.value_limits,
             Keyword.fetch!(state.config.recovery, :max_decode_payload_bytes)
           ),
         {:ok, candidate} <- Auxiliary.reduce(event, %{sequence: state.next_sequence}, seed),
         :ok <- headroom(state, byte_size(payload), state.persistent_settlement_reserve) do
      Tay.State.Memory.transaction(
        state.memory,
        candidate.auxiliary_bytes - state.auxiliary_bytes,
        fn ->
          {writer_result, state} = append_record(state, type, 2, payload)

          case writer_result do
            {:ok, receipt} ->
              validate_receipt!(state, receipt, byte_size(payload))

              {:ok, candidate} =
                Auxiliary.reduce(
                  event,
                  %{sequence: state.next_sequence},
                  auxiliary_seed(state, event, job)
                )

              actual_delta = candidate.auxiliary_bytes - state.auxiliary_bytes

              next = %{
                state
                | schedules: candidate.schedules,
                  auxiliary_bytes: candidate.auxiliary_bytes,
                  schedule_owners:
                    if(event.data["schedule_id"],
                      do:
                        Tay.State.Auxiliary.replace_owners(
                          state.schedule_owners,
                          state.schedules[event.data["schedule_id"]],
                          candidate.schedules[event.data["schedule_id"]]
                        ),
                      else: state.schedule_owners
                    ),
                  results: candidate.results,
                  next_sequence: state.next_sequence + 1,
                  events_since_checkpoint: state.events_since_checkpoint + 1,
                  history_bytes: state.history_bytes + history_delta(state, byte_size(payload)),
                  segment_count: state.segment_count + receipt.segment_id - state.segment.id,
                  segment: %{
                    id: receipt.segment_id,
                    state: :active,
                    bytes: receipt.offset + byte_size(payload) + 28,
                    count:
                      if(receipt.segment_id == state.segment.id,
                        do: state.segment.count + 1,
                        else: 1
                      )
                  },
                  segment_catalog: update_segment_catalog(state, receipt, byte_size(payload))
              }

              if event.data["schedule_id"],
                do:
                  Tay.State.ScheduleIndex.put(
                    state.schedule_index,
                    candidate.schedules[event.data["schedule_id"]]
                  )

              {:memory_delta, actual_delta, {:ok, next}}

            {:error, reason} ->
              {:error, reason}

            _ ->
              exit(:writer_commit_unknown)
          end
        end
      )
    end
  end

  defp auxiliary_seed(state, event, job) do
    schedule = state.schedules[event.data["schedule_id"]]
    ids = if schedule, do: Map.get(schedule, :active_job_ids, []), else: []
    ids = Enum.uniq(ids ++ List.wrap(event.data["active_job_id"]))

    jobs =
      Enum.reduce(ids, %{}, fn encoded, acc ->
        with {:ok, raw} <- Tay.JobID.decode(encoded),
             value when not is_nil(value) <- ProjectionState.lookup(state, raw),
             do: Map.put(acc, raw, value),
             else: (_ -> acc)
      end)

    jobs = if job, do: Map.put(jobs, job.id, job), else: jobs

    %{
      Transition.candidate(state.config.candidate_limits, state.config.value_limits)
      | jobs: jobs,
        schedules: state.schedules,
        results: state.results,
        bytes: state.budget.bytes + state.auxiliary_bytes,
        auxiliary_bytes: state.auxiliary_bytes
    }
  end

  defp append_record(state, type, schema, payload) do
    case Writer.append(state.writer, state.admission, type, schema, payload) do
      {:ok, receipt, {:online_compaction, stats}} ->
        {_token, retention} = state.online_compaction
        adopted = OnlineCheckpoint.adopt(state, stats, retention)
        {{:ok, receipt}, %{adopted | online_compaction: {:switched, state.online_compaction}}}

      result ->
        {result, state}
    end
  end

  defp commit_v2(state, previous, event) do
    ensure_generation_live!(state)

    with {:ok, mutation} <-
           Mutation.from_event(event, previous, state.next_availability_order),
         {:ok, payload} <- Codec.encode_mutation(mutation, state.config.value_limits),
         {:ok, predicted, next_order} <-
           V2Reducer.apply_one(
             previous,
             mutation,
             state.next_availability_order,
             state.config.candidate_limits,
             state.config.value_limits
           ),
         reserve = reservation_after(state, previous, event.record_type),
         :ok <- headroom(state, byte_size(payload), reserve),
         {:ok, job, budget} <- ProjectionState.account_active(state, previous, predicted) do
      Tay.State.Memory.transaction(state.memory, budget.bytes - state.budget.bytes, fn ->
        hook(state.config, {:execution, event.record_type, :pre_append})
        hook(state.config, :pre_append)
        {writer_result, state} = append_record(state, 8, 1, payload)

        case writer_result do
          {:ok, receipt} ->
            validate_receipt!(state, receipt, byte_size(payload))
            hook(state.config, :post_append)
            hook(state.config, {:execution, event.record_type, :post_append})

            finish_commit(
              state,
              previous,
              job,
              budget,
              receipt,
              payload,
              reserve,
              event.record_type,
              next_order
            )

          {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
            {:error, reason}

          _ ->
            exit(:writer_commit_unknown)
        end
      end)
    end
  end

  defp commit_volatile(state, previous, event) do
    ensure_generation_live!(state)

    with {:ok, mutation} <-
           Mutation.from_event(event, previous, state.volatile_next_availability_order),
         {:ok, _payload} <- Codec.encode_mutation(mutation, state.config.value_limits),
         {:ok, predicted, next_order} <-
           V2Reducer.apply_one(
             previous,
             mutation,
             state.volatile_next_availability_order,
             state.config.candidate_limits,
             state.config.value_limits
           ),
         {:ok, job, budget} <-
           ProjectionState.account_active(state, previous, predicted, :volatile) do
      Tay.State.Memory.transaction(state.memory, budget.bytes - state.budget.bytes, fn ->
        job = Map.put(job, :terminal_at, CompactionEstimate.terminal_time(job, event.data["at"]))
        :ok = ProjectionState.publish(state, previous, job, :volatile)
        reserve = reservation_after(state, previous, event.record_type, :volatile)

        next = %{
          state
          | volatile_ids: MapSet.put(state.volatile_ids, job.id),
            volatile_next_availability_order: next_order,
            budget: budget,
            active_budget:
              ProjectionState.replace_partition(
                state.active_budget,
                previous,
                job,
                :active,
                :volatile
              ),
            volatile_terminal_budget:
              ProjectionState.replace_partition(
                state.volatile_terminal_budget,
                previous,
                job,
                :terminal
              ),
            blocked: state.blocked - blocked_charge(state, previous) + blocked_charge(state, job),
            settlement_reserve: reserve
        }

        next =
          next
          |> record_start(event.record_type, job)
          |> record_transition(telemetry_operation(event.record_type), previous, job)
          |> maybe_schedule_memory_reclaim(previous, job)
          |> ProjectionState.ensure_active_accounting!()

        hook(state.config, :post_projection)
        hook(state.config, {:execution, event.record_type, :post_projection})
        {:ok, job, next}
      end)
    end
  end

  defp commit_volatile_auxiliary(state, event, job) do
    ensure_generation_live!(state)

    seed = auxiliary_seed(state, event, job)

    with {:ok, {_, 2, _}} <-
           Event.encode(
             event,
             state.config.value_limits,
             Keyword.fetch!(state.config.recovery, :max_decode_payload_bytes)
           ),
         {:ok, candidate} <- Auxiliary.reduce(event, %{sequence: 1}, seed) do
      Tay.State.Memory.transaction(
        state.memory,
        candidate.auxiliary_bytes - state.auxiliary_bytes,
        fn ->
          {:ok, %{state | results: candidate.results, auxiliary_bytes: candidate.auxiliary_bytes}}
        end
      )
    end
  end

  defp finish_commit(
         state,
         previous,
         job,
         _budget,
         receipt,
         payload,
         reserve,
         operation,
         next_order
       ) do
    {:ok, job, budget} = ProjectionState.account_active(state, previous, job)
    :ok = ProjectionState.publish(state, previous, job)

    next = %{
      state
      | budget: budget,
        active_budget:
          ProjectionState.replace_partition(state.active_budget, previous, job, :active),
        terminal_budget:
          ProjectionState.replace_partition(state.terminal_budget, previous, job, :terminal),
        terminal_stats:
          ProjectionState.replace_terminal_stats(state.terminal_stats, previous, job),
        compaction_estimate: CompactionEstimate.replace(state.compaction_estimate, previous, job),
        blocked: state.blocked - blocked_charge(state, previous) + blocked_charge(state, job),
        next_sequence: state.next_sequence + 1,
        events_since_checkpoint: state.events_since_checkpoint + 1,
        next_availability_order: next_order || state.next_availability_order,
        settlement_reserve: reservation_after(state, previous, operation, :all),
        persistent_settlement_reserve: reserve,
        history_bytes: state.history_bytes + history_delta(state, byte_size(payload)),
        segment_count: state.segment_count + receipt.segment_id - state.segment.id,
        segment: %{
          id: receipt.segment_id,
          state: :active,
          bytes: receipt.offset + byte_size(payload) + 28,
          count: if(receipt.segment_id == state.segment.id, do: state.segment.count + 1, else: 1)
        },
        segment_catalog: update_segment_catalog(state, receipt, byte_size(payload))
    }

    next =
      next
      |> record_start(operation, job)
      |> record_transition(telemetry_operation(operation), previous, job)
      |> maybe_schedule_memory_reclaim(previous, job)
      |> ProjectionState.ensure_active_accounting!()

    hook(state.config, :post_projection)

    hook(
      state.config,
      {:execution, operation, :post_projection}
    )

    {:ok, job, next}
  end

  defp validate_receipt!(state, receipt, payload_bytes) do
    expected = expected_position(state, payload_bytes)

    if receipt != Map.put(expected, :durability, state.config.durability),
      do: exit(:invalid_writer_receipt)
  end

  defp record_start(state, 3, job) do
    limiter =
      Tay.Execution.RateLimiter.consume(
        state.rate_limiter,
        job.definition["queue_key"],
        job.definition["worker_key"],
        Tay.Execution.Clock.monotonic(state.config.clock)
      )

    %{state | rate_limiter: limiter}
  end

  defp record_start(state, _, _), do: state

  defp record_transition(%{deferred_transitions: transitions} = state, operation, previous, job)
       when is_list(transitions) do
    %{state | deferred_transitions: [{operation, previous, job} | transitions]}
  end

  defp record_transition(state, operation, previous, job) do
    Tay.Telemetry.transition(state.config.name, operation, previous, job)
    state
  end

  def ensure_generation_live!(%{fence: nil}), do: :ok

  def ensure_generation_live!(state) do
    if LocalFence.live?(state.fence), do: :ok, else: exit(:execution_generation_revoked)
  end

  defp reservation_after(state, previous, type),
    do: reservation_after(state, previous, type, :persistent)

  defp reservation_after(state, _previous, 3, :persistent),
    do: state.persistent_settlement_reserve + 1

  defp reservation_after(state, %{state: :executing}, type, :persistent)
       when type in [4, 5],
       do: state.persistent_settlement_reserve - 1

  defp reservation_after(state, _previous, _type, :persistent),
    do: state.persistent_settlement_reserve

  defp reservation_after(state, _previous, 3, mode) when mode in [:volatile, :all],
    do: state.settlement_reserve + 1

  defp reservation_after(state, %{state: :executing}, type, mode)
       when type in [4, 5] and mode in [:volatile, :all],
       do: state.settlement_reserve - 1

  defp reservation_after(state, _previous, _type, mode) when mode in [:volatile, :all],
    do: state.settlement_reserve

  defp telemetry_operation(1), do: :insert
  defp telemetry_operation(2), do: :make_available
  defp telemetry_operation(3), do: :start
  defp telemetry_operation(4), do: :finish
  defp telemetry_operation(5), do: :cancel
  defp telemetry_operation(6), do: :retry

  defp expected_position(state, payload_bytes) do
    rotate =
      state.segment.count > 0 and
        (state.segment.state == :sealed or
           state.segment.bytes + payload_bytes + 28 + 64 > state.config.rotation_target_bytes)

    %{
      sequence: state.next_sequence,
      segment_id: state.segment.id + if(rotate, do: 1, else: 0),
      offset: if(rotate, do: 44, else: state.segment.bytes)
    }
  end

  def headroom(state, bytes, reserve) do
    cond do
      state.next_sequence + reserve > Segment.max_id() ->
        {:error, :sequence_exhausted}

      expected_position(state, bytes).segment_id + reserve > Segment.max_id() ->
        {:error, :segment_id_exhausted}

      over_limit?(
        state.history_bytes + history_delta(state, bytes) + outcome_reserve(reserve),
        state.config.max_history_bytes
      ) ->
        {:error, {:resource_limit, :max_history_bytes}}

      over_limit?(
        state.segment_count + expected_position(state, bytes).segment_id - state.segment.id +
            reserve,
        state.config.max_segments
      ) ->
        {:error, {:resource_limit, :max_segments}}

      true ->
        :ok
    end
  end

  # Fixed conservative operational reservation, not a persisted format limit.
  defp outcome_reserve(count), do: count * (1_024 + 64 + 44)
  defp over_limit?(_, :infinity), do: false
  defp over_limit?(value, limit), do: value > limit

  defp history_delta(state, bytes) do
    rotates = expected_position(state, bytes).segment_id != state.segment.id

    bytes + 28 +
      if(rotates, do: 44 + if(state.segment.state == :sealed, do: 0, else: 64), else: 0)
  end

  defp blocked_charge(state, job) do
    if ProjectionState.blocked?(state.projection, state.config, job), do: 1, else: 0
  end

  defp maybe_schedule_memory_reclaim(state, _previous, _job)
       when state.active_budget.count > 0 or map_size(state.running) > 0 do
    if state.memory_reclaim, do: Process.cancel_timer(elem(state.memory_reclaim, 0))
    %{state | memory_reclaim: nil, memory_reclaimed: false}
  end

  defp maybe_schedule_memory_reclaim(
         %{memory_reclaim: nil, memory_reclaimed: false} = state,
         previous,
         job
       ) do
    if not ProjectionState.terminal?(previous) and ProjectionState.terminal?(job),
      do: schedule_memory_reclaim(state),
      else: state
  end

  defp maybe_schedule_memory_reclaim(state, _previous, _job), do: state

  defp schedule_memory_reclaim(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:reclaim_memory, token}, @memory_reclaim_idle_ms)
    %{state | memory_reclaim: {timer, token}}
  end

  defp update_segment_catalog(state, receipt, payload_bytes) do
    active = %{
      id: receipt.segment_id,
      state: :active,
      bytes: receipt.offset + payload_bytes + 28,
      count: if(receipt.segment_id == state.segment.id, do: state.segment.count + 1, else: 1),
      first_sequence:
        if(receipt.segment_id == state.segment.id,
          do: List.last(state.segment_catalog).first_sequence,
          else: state.next_sequence
        ),
      last_sequence: state.next_sequence
    }

    catalog =
      if receipt.segment_id == state.segment.id do
        List.replace_at(state.segment_catalog, -1, active)
      else
        sealed =
          state.segment_catalog
          |> List.last()
          |> Map.merge(%{state: :sealed, bytes: state.segment.bytes + 64})

        state.segment_catalog
        |> List.replace_at(-1, sealed)
        |> Kernel.++([active])
      end

    Enum.take(catalog, -@segment_catalog_limit)
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
