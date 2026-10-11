defmodule Tay.Storage.Writer.Compaction do
  @moduledoc false

  alias Tay.Storage.{Native, Reader}
  alias Tay.Storage.V2.{CompactionControl, Publisher, Reclaimer, Snapshot, V1Migration}
  alias Tay.Storage.V2.Reader, as: V2Reader
  alias Tay.Storage.V2.Reducer, as: V2Reducer
  alias Tay.Storage.Writer.SegmentOps

  @test Mix.env() == :test
  @reacquire_timeout_ms 5_000
  @reacquire_poll_ms 10

  def run(state, deadline, retention, captured_at, cancel_flag) do
    state = %{state | native: %{state.native | deadline: deadline}}
    CompactionControl.install(cancel_flag)

    try do
      case compact_source(state, retention, captured_at) do
        {:ok, next, stats} -> {:ok, %{next | compacted: true}, stats}
        {:error, reason} -> {:error, state, reason}
      end
    after
      CompactionControl.clear()
    end
  end

  defp compact_source(state, retention, captured_at) do
    with {:ok, state} <- seal_frontier(state),
         {:ok, jobs, current} <- replay_source(state) do
      source =
        %{
          store_id: state.store_id,
          epoch_id: state.epoch_id,
          current: current,
          jobs: jobs,
          frontier: state.next_sequence - 1,
          rotation_target_bytes: state.options.rotation_target_bytes,
          candidate_limits: state.candidate_limits,
          value_limits: state.value_limits,
          terminal_retention: retention,
          captured_at:
            if(is_nil(captured_at), do: System.system_time(:millisecond), else: captured_at)
        }
        |> with_hook(state)

      result =
        case Publisher.publish(state.native, source) do
          {:error, {:unknown_publication_outcome, publication}} ->
            reconcile_publication(state, jobs, publication)

          other ->
            other
        end

      adopt_result(state, result)
    end
  end

  defp adopt_result(state, {:ok, %{recovered: recovered} = stats}) do
    native = Map.get(stats, :native, state.native)

    reclaimed =
      if Map.has_key?(stats, :native) or CompactionControl.requested?() do
        %{reclamation: :deferred, reclaimed_bytes: 0}
      else
        case Reclaimer.predecessor(native, recovered) do
          {:ok, details} -> details
          _ -> %{reclamation: :deferred, reclaimed_bytes: 0}
        end
      end

    stats = stats |> Map.delete(:native) |> Map.merge(reclaimed)

    {:ok,
     %{
       state
       | epoch_id: recovered.epoch_id,
         v2_current: recovered.current,
         segment: recovered.highest,
         next_sequence: recovered.next_sequence,
         native: native,
         retired_ports:
           if(native.port != state.native.port,
             do: MapSet.put(state.retired_ports, state.native.port),
             else: state.retired_ports
           )
     }, stats}
  end

  defp adopt_result(_state, error), do: error

  defp reconcile_publication(state, jobs, publication) do
    # The first Port may have completed the rename and lost only its reply.
    Native.close(state.native)

    options = [
      durability: state.options.durability,
      validated_filesystem: state.options.validated_filesystem,
      test_helper: state.options.test_helper,
      timeout: state.options.timeout
    ]

    with {:ok, native} <- reacquire(state.options.data_dir, options) do
      result = verify_reconciled(state, native, jobs, publication)

      if match?({:ok, _}, result) do
        result
      else
        Native.shutdown(native)
        {:error, result}
      end
    end
  end

  defp verify_reconciled(state, native, jobs, publication) do
    with {:ok, recovered} <-
           V2Reader.recover(
             native,
             V2Reducer.candidate(state.candidate_limits, state.value_limits)
           ),
         true <- recovered.epoch_id == publication.epoch_id || {:error, :old_current},
         true <- recovered.current == publication.current || {:error, :current_changed},
         {:ok, retained, _, _} <-
           Snapshot.prepare(jobs, publication.terminal_retention, publication.captured_at),
         true <-
           Snapshot.equivalent?(retained, recovered.candidate.jobs) ||
             {:error, :reconciled_candidate_mismatch} do
      {:ok,
       publication
       |> Map.drop([:current, :started, :reason])
       |> Map.merge(%{
         native: native,
         recovered: recovered,
         pause_ms: System.monotonic_time(:millisecond) - publication.started,
         reclamation: :deferred,
         reclaimed_bytes: 0,
         publication_reconciled: true
       })}
    end
  end

  defp reacquire(path, options) do
    deadline = System.monotonic_time(:millisecond) + @reacquire_timeout_ms
    do_reacquire(path, options, deadline)
  end

  defp do_reacquire(path, options, deadline) do
    case Native.open_existing(path, options) do
      {:error, %{reason: "store_busy"}} = busy ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@reacquire_poll_ms)
          do_reacquire(path, options, deadline)
        else
          busy
        end

      result ->
        result
    end
  end

  defp seal_frontier(%{segment: %{state: :active, count: count}} = state) when count > 0 do
    with {:ok, rotated} <- SegmentOps.rotate(state),
         :ok <- Native.sync(rotated.native),
         :ok <- Native.close_write(rotated.native),
         :ok <- Native.sync_dir(rotated.native, :segments),
         do: {:ok, rotated}
  end

  defp seal_frontier(%{segment: %{state: :active}} = state) do
    with :ok <- Native.sync(state.native),
         :ok <- Native.close_write(state.native),
         :ok <- Native.sync_dir(state.native, :segments),
         do: {:ok, state}
  end

  defp seal_frontier(state), do: {:ok, state}

  defp replay_source(%{epoch_id: nil} = state) do
    options = Map.to_list(state.recovery.options)

    with {:ok, view} <- Reader.preflight(state.native, options),
         true <-
           (view.store.store_id == state.store_id and
              view.store.next_sequence == state.next_sequence) ||
             {:error, :compaction_source_changed},
         {:ok, migrated} <-
           Reader.reduce_while(
             state.native,
             view,
             V1Migration.candidate(state.candidate_limits, state.value_limits),
             fn record, position, acc ->
               with {:ok, event, _} <-
                      Tay.Event.decode_payload(
                        record.record_type,
                        record.payload_schema_version,
                        record.payload,
                        state.value_limits
                      ),
                    {:ok, next} <- V1Migration.reduce(acc, event, position),
                    do: {:cont, next}
             end,
             options
           ) do
      {:ok, migrated.v2.jobs, nil}
    end
  end

  defp replay_source(state) do
    with {:ok, recovered} <-
           V2Reader.recover(
             state.native,
             V2Reducer.candidate(state.candidate_limits, state.value_limits),
             selected: true
           ),
         true <- recovered.epoch_id == state.epoch_id || {:error, :source_epoch_changed},
         true <- recovered.current == state.v2_current || {:error, :source_current_changed},
         true <-
           recovered.next_sequence == state.next_sequence || {:error, :source_frontier_changed} do
      {:ok, recovered.candidate.jobs, recovered.current}
    end
  end

  if @test do
    defp with_hook(source, %{options: %{on_transition: fun}, native: native})
         when is_function(fun, 2),
         do: Map.put(source, :on_boundary, fn tag -> fun.({:compaction, tag}, native) end)

    defp with_hook(source, _state), do: source
  else
    defp with_hook(source, _state), do: source
  end
end
