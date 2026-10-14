defmodule Tay.Engine.Persistence do
  @moduledoc false

  alias Tay.Event
  alias Tay.Engine.{CompactionEstimate, OnlineCheckpoint, ProjectionState}
  alias Tay.Execution.LocalFence
  alias Tay.State.Transition
  alias Tay.State.Auxiliary
  alias Tay.Storage.{Segment, Writer}
  alias Tay.Storage.V2.{Codec, V1Migration}
  alias Tay.Storage.V2.Reducer, as: V2Reducer

  @memory_reclaim_idle_ms 1_000
  @segment_catalog_limit 128

  def commit(state, previous, event, encoded \\ nil)

  def commit(%{epoch_id: epoch_id} = state, previous, event, _encoded)
      when is_binary(epoch_id) do
    commit_v2(state, previous, event)
  end

  def commit(state, previous, event, encoded) do
    ensure_generation_live!(state)

    with {:ok, {type, schema, payload}} <- encoded_event(state, event, encoded),
         {:ok, effect} <- Transition.prepare(previous, event, state.config.value_limits),
         reserve = reservation_after(state, previous, type),
         :ok <- headroom(state, byte_size(payload), reserve),
         {:ok, predicted} <- Transition.apply(effect, %{sequence: state.next_sequence}),
         {:ok, _, budget} <- ProjectionState.account_active(state, previous, predicted) do
      hook(state.config, {:execution, type, :pre_append})
      hook(state.config, :pre_append)

      case Writer.append(state.writer, state.admission, type, schema, payload) do
        {:ok, receipt} ->
          validate_receipt!(state, receipt, byte_size(payload))
          hook(state.config, :post_append)
          hook(state.config, {:execution, type, :post_append})
          {:ok, job} = Transition.apply(effect, receipt)
          {:ok, job, ^budget} = ProjectionState.account_active(state, previous, job)

          job =
            Map.put(job, :terminal_at, CompactionEstimate.terminal_time(job, event.data["at"]))

          finish_commit(state, previous, job, budget, receipt, payload, reserve, type)

        {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
          {:error, reason}

        _ ->
          exit(:writer_commit_unknown)
      end
    end
  end

  def encoded_event(state, event, nil) do
    Event.encode(
      event,
      state.config.value_limits,
      Keyword.fetch!(state.config.recovery, :max_decode_payload_bytes)
    )
  end

  def encoded_event(_state, event, payload), do: {:ok, {event.record_type, 1, payload}}

  def commit_auxiliary(state, event, job \\ nil) do
    ensure_generation_live!(state)

    seed = %{
      Transition.candidate(state.config.candidate_limits, state.config.value_limits)
      | jobs: if(job, do: %{job.id => job}, else: %{}),
        schedules: state.schedules,
        results: state.results
    }

    with {:ok, {type, 2, payload}} <-
           Event.encode(
             event,
             state.config.value_limits,
             Keyword.fetch!(state.config.recovery, :max_decode_payload_bytes)
           ),
         {:ok, candidate} <- Auxiliary.reduce(event, %{sequence: state.next_sequence}, seed),
         :ok <- headroom(state, byte_size(payload), state.settlement_reserve) do
      {writer_result, state} = append_auxiliary(state, type, payload)

      case writer_result do
        {:ok, receipt} ->
          validate_receipt!(state, receipt, byte_size(payload))

          next = %{
            state
            | schedules: candidate.schedules,
              results: Map.merge(state.results, candidate.results),
              next_sequence: state.next_sequence + 1,
              events_since_checkpoint: state.events_since_checkpoint + 1,
              history_bytes: state.history_bytes + history_delta(state, byte_size(payload)),
              segment_count: state.segment_count + receipt.segment_id - state.segment.id,
              segment: %{
                id: receipt.segment_id,
                state: :active,
                bytes: receipt.offset + byte_size(payload) + 28,
                count:
                  if(receipt.segment_id == state.segment.id, do: state.segment.count + 1, else: 1)
              },
              segment_catalog: update_segment_catalog(state, receipt, byte_size(payload))
          }

          {:ok, next}

        {:error, reason} ->
          {:error, reason}

        _ ->
          exit(:writer_commit_unknown)
      end
    end
  end

  defp append_auxiliary(%{epoch_id: epoch} = state, type, payload) when is_binary(epoch),
    do: append_v2_record(state, type, 2, payload)

  defp append_auxiliary(state, type, payload),
    do: {Writer.append(state.writer, state.admission, type, 2, payload), state}

  defp append_v2_record(state, type, schema, payload) do
    case Writer.append(state.writer, state.admission, type, schema, payload) do
      {:ok, receipt, {:online_compaction, stats}} ->
        adopted = OnlineCheckpoint.adopt(state, stats)
        {{:ok, receipt}, %{adopted | online_compaction: {:switched, state.online_compaction}}}

      result ->
        {result, state}
    end
  end

  defp commit_v2(state, previous, event) do
    ensure_generation_live!(state)

    with {:ok, mutation} <-
           V1Migration.translate_event(event, previous, state.next_availability_order),
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
      hook(state.config, {:execution, 8, :pre_append})
      hook(state.config, :pre_append)
      {writer_result, state} = append_v2(state, payload)

      case writer_result do
        {:ok, receipt} ->
          validate_receipt!(state, receipt, byte_size(payload))
          hook(state.config, :post_append)
          hook(state.config, {:execution, 8, :post_append})

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
    end
  end

  defp append_v2(state, payload) do
    case Writer.append(state.writer, state.admission, 8, 1, payload) do
      {:ok, receipt, {:online_compaction, stats}} ->
        adopted = OnlineCheckpoint.adopt(state, stats)
        {{:ok, receipt}, %{adopted | online_compaction: {:switched, state.online_compaction}}}

      result ->
        {result, state}
    end
  end

  defp finish_commit(
         state,
         previous,
         job,
         budget,
         receipt,
         payload,
         reserve,
         operation,
         next_order \\ nil
       ) do
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
        settlement_reserve: reserve,
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
      |> record_transition(telemetry_operation(operation), previous, job)
      |> maybe_schedule_memory_reclaim(previous, job)
      |> ProjectionState.ensure_active_accounting!()

    hook(state.config, :post_projection)

    hook(
      state.config,
      {:execution, if(is_binary(state.epoch_id), do: 8, else: operation), :post_projection}
    )

    {:ok, job, next}
  end

  defp validate_receipt!(state, receipt, payload_bytes) do
    expected = expected_position(state, payload_bytes)

    if receipt != Map.put(expected, :durability, state.config.durability),
      do: exit(:invalid_writer_receipt)
  end

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

  defp reservation_after(state, _previous, 3), do: state.settlement_reserve + 1

  defp reservation_after(state, %{state: :executing}, type) when type in [4, 5],
    do: state.settlement_reserve - 1

  defp reservation_after(state, _previous, _type), do: state.settlement_reserve

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
