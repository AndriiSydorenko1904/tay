defmodule Tay.Storage.Writer.OnlineCompactionLifecycle do
  @moduledoc false

  alias Tay.Storage.{Native, Segment}
  alias Tay.Storage.V2.{CompactionControl, Publisher, Reader, Reclaimer, Reducer, Retention}
  alias Tay.Storage.Writer.{OnlineCompaction, SegmentOps, Session}

  @maintenance_io_timeout_ms 120_000
  @reacquire_timeout_ms 5_000
  @reacquire_poll_ms 10
  @test Mix.env() == :test

  def native_request(state, native, deadline, cancel_flag, operation, body) do
    result =
      cond do
        :atomics.get(cancel_flag, 1) == 1 ->
          {:error, %{kind: :resource_limit, reason: :compaction_cancelled}}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, %{kind: :resource_limit, reason: :deadline}}

        true ->
          timeout =
            min(
              min(@maintenance_io_timeout_ms, state.native.timeout),
              max(deadline - System.monotonic_time(:millisecond), 1)
            )

          Native.request_owned(%{native | timeout: timeout}, operation, body)
      end

    state =
      case result do
        {:error, %{kind: :uncertain}} ->
          %{state | retired_ports: MapSet.put(state.retired_ports, state.native.port)}

        _ ->
          state
      end

    {:reply, result, state}
  end

  def start(
        state,
        caller,
        reference,
        deadline,
        retention,
        captured_at,
        cancel_flag,
        notify,
        token,
        snapshot
      ) do
    if admitted?(
         state,
         caller,
         reference,
         deadline,
         retention,
         notify,
         snapshot
       ) do
      do_start(state, deadline, retention, captured_at, cancel_flag, notify, token, snapshot)
    else
      {:reply, {:error, :compaction_not_admitted}, state}
    end
  end

  def poll(state, online) do
    {records, online} = OnlineCompaction.drain(online)
    {:reply, {:ok, records}, %{state | online_compaction: online}}
  end

  def freeze(state, online, from) do
    case OnlineCompaction.freeze(online, from) do
      {:catch_up, records, online} ->
        {:reply, {:catch_up, records}, %{state | online_compaction: online}}

      {:freeze, online} ->
        send(online.notify, {:compact_online_switch_requested, self(), online.token})
        {:noreply, %{state | online_compaction: online}}
    end
  end

  def finish_freeze(state, online, freeze_from) do
    with :ok <- Native.sync(state.native), :ok <- Native.close_write(state.native) do
      {records, online} = OnlineCompaction.finish_freeze(online)
      GenServer.reply(freeze_from, {:ok, records})
      {:reply, :ok, %{state | online_compaction: online}}
    else
      error ->
        GenServer.reply(freeze_from, error)
        {:reply, error, Session.poison(state, error)}
    end
  end

  def complete(state, online, recovered, stats, mutate) do
    Process.demonitor(online.monitor, [:flush])
    native = %{state.native | deadline: nil}

    {:ok, reclaimed} = Reclaimer.predecessor(native, recovered)

    stats =
      stats
      |> Map.merge(reclaimed)
      |> Map.merge(%{
        peak_delta_events: online.peak_delta_events,
        peak_delta_bytes: online.peak_delta_bytes,
        net_reclaimed_bytes:
          max(Map.get(reclaimed, :reclaimed_bytes, 0) - Map.get(stats, :candidate_bytes, 0), 0)
      })

    case Native.open_active(native, canonical(recovered.highest.id), recovered.highest.identity) do
      {:ok, _} ->
        next = %{
          state
          | native: native,
            epoch_id: recovered.epoch_id,
            v2_current: recovered.current,
            segment: recovered.highest,
            next_sequence: recovered.next_sequence,
            online_compaction: nil
        }

        {next, delivered} = resume_pending(next, Enum.reverse(online.pending), stats, mutate)

        send(
          online.notify,
          {:compact_online_result, self(), online.token, {:ok, stats, delivered}}
        )

        {:noreply, next, {:continue, :release_transient_heap}}

      error ->
        send(online.notify, {:compact_online_result, self(), online.token, {:error, error}})
        {:noreply, Session.poison(state, error)}
    end
  end

  def fail(state, online, reason, mutate) do
    Process.demonitor(online.monitor, [:flush])
    reason = online.abort_reason || reason

    cond do
      match?({:unknown_publication_outcome, _}, reason) ->
        reconcile_unknown_publication(state, online, reason, mutate)

      not online.freezing and not online.frozen ->
        abort_preparation(state, online, reason)

      true ->
        resume_source(state, online, reason, mutate)
    end
  end

  defp reconcile_unknown_publication(
         state,
         online,
         {:unknown_publication_outcome, publication} = reason,
         mutate
       ) do
    Native.close_and_await(state.native)

    options = [
      durability: state.options.durability,
      validated_filesystem: state.options.validated_filesystem,
      test_helper: state.options.test_helper,
      timeout: state.options.timeout
    ]

    case reacquire(state.options.data_dir, options) do
      {:ok, native} ->
        candidate = Reducer.candidate(state.candidate_limits, state.value_limits)

        case Reader.recover(native, candidate) do
          {:ok, %{epoch_id: epoch_id, current: current} = recovered}
          when epoch_id == publication.epoch_id and current == publication.current ->
            case Native.enable_mutations(native) do
              :ok ->
                stats = reconciled_stats(publication, recovered)

                complete(
                  %{
                    state
                    | native: native,
                      retired_ports: MapSet.put(state.retired_ports, state.native.port)
                  },
                  online,
                  recovered,
                  stats,
                  mutate
                )

              error ->
                reconciliation_failed(state, online, native, reason, error)
            end

          {:ok, %{epoch_id: epoch_id, current: current}}
          when epoch_id == state.epoch_id and current == state.v2_current ->
            case Native.enable_mutations(native) do
              :ok ->
                resume_source(
                  %{
                    state
                    | native: native,
                      retired_ports: MapSet.put(state.retired_ports, state.native.port)
                  },
                  online,
                  reason,
                  mutate
                )

              error ->
                reconciliation_failed(state, online, native, reason, error)
            end

          recovery_error ->
            reconciliation_failed(state, online, native, reason, recovery_error)
        end

      reacquire_error ->
        reconciliation_failed(state, online, nil, reason, reacquire_error)
    end
  end

  defp reconciled_stats(publication, recovered) do
    publication
    |> Map.drop([:current, :started, :switch_started, :reason])
    |> Map.merge(%{
      recovered: recovered,
      preparation_ms: publication.switch_started - publication.started,
      pause_ms: System.monotonic_time(:millisecond) - publication.switch_started,
      total_ms: System.monotonic_time(:millisecond) - publication.started,
      reclamation: :deferred,
      reclaimed_bytes: 0,
      publication_reconciled: true
    })
  end

  defp reconciliation_failed(state, online, native, reason, reconciliation_error) do
    if native, do: Native.shutdown(native)
    error = {:compaction_reconciliation_failed, reason, reconciliation_error}
    send(online.notify, {:compact_online_result, self(), online.token, {:error, error}})
    {:noreply, Session.poison(state, error)}
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

  def builder_down(state, online, reason) do
    error = online.abort_reason || {:builder_exit, reason}

    if not online.freezing and not online.frozen do
      abort_preparation(state, online, error)
    else
      send(online.notify, {:compact_online_result, self(), online.token, {:error, error}})
      {:noreply, Session.poison(state, error)}
    end
  end

  defp admitted?(state, caller, reference, deadline, retention, notify, snapshot) do
    recovery = state.recovery

    is_binary(state.epoch_id) and is_pid(notify) and recovery.status == :ready and
      caller == recovery.caller and reference == recovery.admission_ref and
      is_nil(Map.get(state, :online_compaction)) and is_integer(deadline) and
      deadline > System.monotonic_time(:millisecond) and is_map(snapshot) and
      Map.get(snapshot, :frontier) == state.next_sequence - 1 and
      is_integer(Map.get(snapshot, :next_availability_order)) and
      Retention.validate(retention) == :ok
  end

  defp do_start(state, deadline, retention, captured_at, cancel_flag, notify, token, snapshot) do
    case SegmentOps.rotate(state) do
      {:ok, rotated} ->
        owner = self()
        ref = make_ref()
        compaction_native = %{rotated.native | deadline: deadline, delegate: ref}

        source =
          %{
            store_id: rotated.store_id,
            epoch_id: rotated.epoch_id,
            current: rotated.v2_current,
            frontier: rotated.next_sequence - 1,
            exclude_segment_id: rotated.segment.id,
            rotation_target_bytes: rotated.options.rotation_target_bytes,
            candidate_limits: rotated.candidate_limits,
            value_limits: rotated.value_limits,
            terminal_retention: retention,
            captured_at: captured_at,
            next_availability_order: snapshot.next_availability_order,
            online_catch_up: fn action ->
              GenServer.call(owner, {:compact_online_catch_up, ref, action}, :infinity)
            end
          }
          |> with_hook(rotated)

        {pid, monitor} = spawn_builder(owner, ref, compaction_native, source, cancel_flag)

        online =
          OnlineCompaction.new(
            ref: ref,
            pid: pid,
            monitor: monitor,
            deadline: deadline,
            cancel_flag: cancel_flag,
            notify: notify,
            token: token,
            source: rotated
          )

        rotation = %{
          previous: Map.take(state.segment, [:id, :state, :bytes, :count]),
          segment: Map.take(rotated.segment, [:id, :state, :bytes, :count]),
          next_sequence: rotated.next_sequence
        }

        {:reply, {:ok, rotation}, Map.put(rotated, :online_compaction, online)}

      error ->
        {:reply, error, state}
    end
  end

  defp spawn_builder(owner, ref, native, source, cancel_flag) do
    spawn_monitor(fn ->
      CompactionControl.install(cancel_flag)

      result =
        try do
          Publisher.publish(native, source)
        after
          CompactionControl.clear()
        end

      send(owner, {:compact_online_result, ref, self(), result})
    end)
  end

  defp abort_preparation(state, online, reason) do
    native = %{state.native | deadline: nil}

    case Native.v2_abort(native) do
      :ok ->
        send(online.notify, {:compact_online_result, self(), online.token, {:error, reason}})

        {:noreply, %{state | native: native, online_compaction: nil},
         {:continue, :release_transient_heap}}

      {:error, abort_reason} ->
        error = {:compaction_abort_failed, reason, abort_reason}
        send(online.notify, {:compact_online_result, self(), online.token, {:error, error}})
        {:noreply, Session.poison(state, error)}
    end
  end

  defp resume_source(state, online, reason, mutate) do
    native = %{state.native | deadline: nil}

    with :ok <- Native.v2_abort(native),
         {:ok, _} <-
           Native.open_active(native, canonical(state.segment.id), state.segment.identity) do
      next = %{state | native: native, online_compaction: nil}
      {next, _} = resume_pending(next, Enum.reverse(online.pending), nil, mutate)
      send(online.notify, {:compact_online_result, self(), online.token, {:error, reason}})
      {:noreply, next, {:continue, :release_transient_heap}}
    else
      rollback_error ->
        error = {:compaction_source_resume_failed, reason, rollback_error}
        send(online.notify, {:compact_online_result, self(), online.token, {:error, error}})
        {:noreply, Session.poison(state, error)}
    end
  end

  defp resume_pending(state, pending, stats, mutate) do
    Enum.reduce(pending, {state, false}, fn {from, request}, {acc, delivered} ->
      case mutate.(request, from, acc) do
        {:reply, reply, next} ->
          reply = tagged_reply(reply, stats, delivered)
          GenServer.reply(from, reply)
          {next, delivered or match?({:ok, _, {:online_compaction, _}}, reply)}
      end
    end)
  end

  defp tagged_reply({:ok, value}, stats, false) when is_map(stats),
    do: {:ok, value, {:online_compaction, stats}}

  defp tagged_reply(reply, _stats, _delivered), do: reply

  if @test do
    defp with_hook(source, %{options: %{on_transition: fun}, native: native})
         when is_function(fun, 2),
         do: Map.put(source, :on_boundary, fn tag -> fun.({:compaction, tag}, native) end)

    defp with_hook(source, _state), do: source
  else
    defp with_hook(source, _state), do: source
  end

  defp canonical(id), do: elem(Segment.filename(id), 1)
end
