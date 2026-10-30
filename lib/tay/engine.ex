defmodule Tay.Engine do
  @moduledoc """
  One generation's semantic command owner and sole private-index owner.
  The log is authoritative. Live producers use the same pure Event transition
  model as recovery; callback execution never runs in this process.
  """
  use GenServer, restart: :temporary
  alias Tay.{Event, Error, JobID}
  alias Tay.Event.{V2, Value}

  alias Tay.Engine.{
    Admission,
    Commands,
    Config,
    CompactionEstimate,
    CompactionReplay,
    GroupCommit,
    OnlineCheckpoint,
    Persistence,
    ProjectionState
  }

  alias Tay.State.{
    JobIndex,
    Projection,
    TerminalStore,
    Transition
  }

  alias Tay.Execution.{Clock, Dispatcher, Registry, LocalFence}
  alias Tay.Engine.{Execution, State}
  alias Tay.Storage.Writer
  @memory_reclaim_idle_ms 1_000
  @segment_catalog_limit 128

  def start_link(config), do: GenServer.start_link(__MODULE__, config, timeout: :infinity)

  def init(config) do
    guardian = Process.whereis(config.name)
    Process.monitor(guardian)

    with {:ok, generation} <- GenServer.call(guardian, {:attach_engine, self()}),
         :ok <- initialize_storage(config),
         {:ok, writer} <-
           Writer.start_recovered_link(
             Config.storage(config) ++ [lifecycle_observer: guardian],
             %{
               codec: Event,
               initial_acc: Transition.candidate(config.candidate_limits, config.value_limits),
               reducer: &CompactionReplay.reduce/3,
               options: config.recovery
             }
           ),
         :ok <- GenServer.call(guardian, {:attach_writer, writer}),
         :ok <- acquire_local_fence(config, guardian, writer, generation),
         {:ok, admission_meta} <- Admission.metadata(config.name),
         inspection = Writer.status(writer),
         {:ok, summary, candidate} <-
           Writer.activate_recovered(writer, inspection.session_ref),
         :ok <- Tay.State.Memory.reserve(admission_meta.memory, candidate.bytes),
         config = OnlineCheckpoint.recovered_config(config, summary),
         :ok <-
           GenServer.call(
             guardian,
             {:compaction_retention, self(), config.compaction.terminal_retention}
           ),
         {:ok, terminal_store} <- TerminalStore.open(config.name, config.data_dir, candidate.jobs) do
      case activation_capability(summary) do
        {:error, error} ->
          TerminalStore.close(terminal_store)
          GenServer.stop(writer)
          {:stop, error}

        {:ok, _reference} ->
          hook(config, :activated)
          # Only explicit trusted configuration atoms are loaded, never persisted
          # keys. This is runtime setup after pure replay, not semantic decoding.
          if config.execution,
            do: Enum.each(config.workers, fn {_, module} -> Code.ensure_loaded(module) end)

          dispatch_registry =
            if config.execution,
              do:
                Map.filter(config.workers, fn {key, _} ->
                  match?({:ok, _}, Registry.resolve(config.workers, key))
                end),
              else: config.workers

          active_jobs =
            Map.reject(candidate.jobs, fn {_id, job} -> ProjectionState.terminal?(job) end)

          projection =
            Projection.new(dispatch_registry, config.queues, Map.get(config, :test_hook))

          hook(config, :indexes_created)
          projection = Projection.load(projection, active_jobs)
          true = Projection.valid?(projection)
          {active_budget, terminal_budget} = ProjectionState.partition_budgets(candidate.jobs)
          budget = candidate |> Transition.accounting() |> Map.merge(active_budget)
          # No copy of candidate.jobs survives init. Active jobs live in private
          # ETS; terminal history lives in a disposable disk projection. Startup
          # accounting reserves up to three charged active views.
          state = %State{
            config: config,
            guardian: guardian,
            generation: generation,
            writer: writer,
            admission: summary.admission_ref,
            projection: projection,
            terminal_store: terminal_store,
            memory: admission_meta.memory,
            auxiliary_bytes: candidate.auxiliary_bytes,
            schedule_owners: Tay.State.Auxiliary.owners(candidate.schedules),
            schedule_index: Tay.State.ScheduleIndex.new(candidate.schedules),
            schedules: candidate.schedules,
            results: candidate.results,
            terminal_stats: ProjectionState.terminal_statistics(candidate.jobs),
            budget: budget,
            active_budget: active_budget,
            terminal_budget: terminal_budget,
            volatile_terminal_budget: %{count: 0, bytes: 0},
            compaction_estimate:
              Enum.reduce(candidate.jobs, CompactionEstimate.new(), fn {_, job}, acc ->
                CompactionEstimate.replace(acc, nil, job)
              end),
            # Capture precedes construction, not publication. Recovered activation
            # is a conservative post-publication cooldown anchor; a restart may
            # extend cooldown but must never shorten it by construction time.
            last_compaction_at:
              case Map.get(summary, :compaction_captured_at) do
                nil -> nil
                captured -> max(captured, Clock.wall(config.clock))
              end,
            last_checkpoint_at:
              case Map.get(summary, :compaction_captured_at) do
                captured when is_integer(captured) and captured > 0 -> captured
                _ -> nil
              end,
            events_since_checkpoint:
              Map.get(summary, :checkpoint_tail_events, summary.record_count),
            store_id: summary.store_id,
            epoch_id: Map.fetch!(summary, :epoch_id),
            rate_limiter: Tay.Execution.RateLimiter.new(config.rate_limits),
            next_availability_order: Map.get(candidate, :next_availability_order, 1),
            volatile_next_availability_order: 1,
            volatile_ids: MapSet.new(),
            next_sequence: summary.arithmetic_next_sequence,
            segment: Map.take(summary.highest, [:id, :bytes, :count, :state]),
            segment_catalog: Enum.take(summary.segment_catalog, -@segment_catalog_limit),
            runtime: GenServer.call(guardian, :runtime),
            fence: GenServer.call(guardian, :fence),
            running: %{},
            executions: %{},
            slots: Map.new(config.queue_limits, fn {queue, _} -> {queue, 0} end),
            relay_monitors: %{},
            controls: %{},
            executor_server: nil,
            control_wakes: MapSet.new(),
            snapshot_pending: nil,
            snapshot_dirty: false,
            settlement_reserve: 0,
            persistent_settlement_reserve: 0,
            mode: :ready,
            paused:
              if(config.start_paused, do: MapSet.new(Map.keys(config.queues)), else: MapSet.new()),
            drainers: %{},
            lifecycle_operation: nil,
            lifecycle_fenced: nil,
            online_compaction: nil,
            online_snapshot: nil,
            group_commit: nil,
            deferred_transitions: nil,
            memory_reclaim: nil,
            memory_reclaimed: false,
            history_bytes:
              summary.total_segment_bytes +
                44 * (summary.highest.id - inspection.summary.highest.id),
            segment_count:
              summary.segment_count + summary.highest.id - inspection.summary.highest.id,
            blocked:
              JobIndex.fold(
                projection.jobs,
                fn job, n ->
                  if ProjectionState.blocked?(projection, config, job),
                    do: n + 1,
                    else: n
                end,
                0
              )
          }

          state = if config.execution, do: Execution.reconcile(state), else: state

          hook(config, :pre_ready)

          case Writer.status(writer) do
            %{state: :ready, durability: mode} when mode == config.durability ->
              :ok = GenServer.call(guardian, {:ready, ProjectionState.snapshot(state)})
              {:ok, state, {:continue, :execution_start}}

            _ ->
              {:stop, Error.new(:unavailable, :writer_unavailable)}
          end
      end
    else
      {:error, reason} -> {:stop, startup_error(reason)}
    end
  end

  defp initialize_storage(%{initialize: :never}), do: :ok

  defp initialize_storage(%{initialize: :if_missing} = config),
    do: Writer.initialize_if_missing(Config.storage(config))

  def handle_continue(:execution_start, s) do
    # Recovery necessarily materializes the authoritative job map. At this
    # point terminal jobs have moved to DETS plus the compact inspection index,
    # so force one collection before the Engine enters its steady-state loop.
    :erlang.garbage_collect()
    {:noreply, if(s.config.execution, do: Execution.start_controls(s), else: s)}
  end

  def handle_continue(:release_transient_heap, s) do
    :erlang.garbage_collect()
    {:noreply, s}
  end

  @doc false
  def activation_capability(%{state: :terminal, admission_ref: nil}),
    do: {:error, Error.new(:capacity, :coordinate_space_exhausted)}

  def activation_capability(%{state: :ready, admission_ref: reference})
      when is_reference(reference),
      do: {:ok, reference}

  def activation_capability(_), do: {:error, Error.new(:unavailable, :invalid_activation_result)}

  # Only the trusted guardian sends a command with a submitted permit. An old
  # generation cannot address a newly constructed Engine or use its capability.
  def handle_info({:command, generation, permit, intent, from}, %{generation: generation} = s) do
    if submitted?(s, permit, from) do
      Persistence.ensure_generation_live!(s)

      case intent do
        {:schedule_operation, coordinator, payload} when is_pid(coordinator) ->
          send(coordinator, {:admitted, s.guardian, self(), generation, permit, payload, from})
          send(s.guardian, {:command_yielded, self(), permit})
          {:noreply, s}

        {:drain, deadline} when is_integer(deadline) ->
          s = flush_group_commit(s)

          timer =
            Process.send_after(
              self(),
              {:drain_deadline, permit},
              max(deadline - System.monotonic_time(:millisecond), 0)
            )

          next = %{s | mode: :draining, drainers: Map.put(s.drainers, permit, {from, timer})}
          hook(s.config, {:operations, :draining})
          send(s.guardian, {:command_yielded, self(), permit})
          {:noreply, publish(complete_drains(next))}

        _ ->
          if GroupCommit.batchable?(s, intent) do
            next = GroupCommit.enqueue(s, permit, intent, from)
            next = if GroupCommit.full?(next), do: flush_group_commit(next), else: next
            {:noreply, Execution.wake_controls(next)}
          else
            s = flush_group_commit(s)
            {reply, next} = command(intent, s)
            next = complete_drains(next)
            reply_command(next, permit, from, reply)
            {:noreply, Execution.wake_controls(next)}
          end
      end
    else
      {:noreply, s}
    end
  end

  def handle_info({:flush_group_commit, token}, %{group_commit: %{token: token}} = s),
    do: {:noreply, s |> flush_group_commit() |> Execution.wake_controls()}

  def handle_info({:flush_group_commit, _}, s), do: {:noreply, s}

  def handle_info(
        {:reclaim_memory, token},
        %{memory_reclaim: {_, token}, active_budget: %{count: 0}, running: running} = s
      )
      when map_size(running) == 0 do
    if Process.alive?(s.writer) do
      :erlang.garbage_collect(s.writer)
    end

    if Process.alive?(s.guardian) do
      :erlang.garbage_collect(s.guardian)
    end

    :erlang.garbage_collect()
    hook(s.config, :memory_reclaimed)
    {:noreply, %{s | memory_reclaim: nil, memory_reclaimed: true}}
  end

  def handle_info(
        {:reclaim_memory, token},
        %{memory_reclaim: {_, token}} = s
      ) do
    {:noreply, %{s | memory_reclaim: nil, memory_reclaimed: false}}
  end

  def handle_info({:reclaim_memory, _}, s), do: {:noreply, s}

  def handle_info({:DOWN, _, :process, guardian, _}, %{guardian: guardian} = s),
    do: {:stop, :guardian_lost, s}

  def handle_info(
        {:command_replied, guardian, _slot, _token},
        %{guardian: guardian} = s
      ) do
    hook(s.config, :post_reply)
    {:noreply, s}
  end

  def handle_info(
        {:lifecycle_compact_online, generation, token, guardian, deadline, retention,
         expected_source, cancel_flag},
        %{generation: generation, guardian: guardian, online_compaction: nil} = s
      ) do
    s = flush_group_commit(s)

    cond do
      not is_binary(s.epoch_id) ->
        send(guardian, {:online_compaction_unsupported, self(), token})
        {:noreply, s}

      not is_nil(expected_source) and expected_source != {s.epoch_id, s.next_sequence} ->
        send(guardian, {:operation_source_changed, self(), token})
        {:noreply, s}

      true ->
        snapshot = OnlineCheckpoint.create(s)

        case Writer.compact_online(
               s.writer,
               s.admission,
               deadline,
               retention,
               Clock.wall(s.config.clock),
               cancel_flag,
               self(),
               token,
               snapshot
             ) do
          {:ok, rotation} ->
            case OnlineCheckpoint.adopt_rotation(s, rotation) do
              {:ok, next} ->
                {:noreply, %{next | online_compaction: {token, retention}, online_snapshot: nil}}

              {:error, reason} ->
                exit({:invalid_online_compaction_rotation, reason})
            end

          {:error, reason} ->
            send(guardian, {:online_compaction_result, self(), token, {:error, reason}})
            {:noreply, s}
        end
    end
  end

  def handle_info(
        {:compact_online_switch_requested, writer, token},
        %{writer: writer, online_compaction: {token, _retention}} = s
      ) do
    s = flush_group_commit(s)
    send(s.guardian, {:online_compaction_switch_requested, self(), token})
    {:noreply, s}
  end

  def handle_info(
        {:online_compaction_switch_ack, guardian, token},
        %{guardian: guardian, online_compaction: {token, _retention}} = s
      ) do
    case Writer.finish_online_freeze(s.writer, s.admission, token) do
      :ok -> {:noreply, s}
      {:error, reason} -> exit({:online_compaction_freeze_failed, reason})
    end
  end

  def handle_info(
        {:compact_online_result, writer, token, {:ok, stats, false}},
        %{writer: writer, online_compaction: {token, retention}} = s
      ) do
    OnlineCheckpoint.delete(s.online_snapshot)
    next = %{OnlineCheckpoint.adopt(s, stats, retention) | online_snapshot: nil}
    send(s.guardian, {:online_compaction_result, self(), token, {:ok, stats}})
    {:noreply, publish(Execution.wake_queues(next)), {:continue, :release_transient_heap}}
  end

  def handle_info(
        {:compact_online_result, writer, token, {:ok, stats, true}},
        %{writer: writer, online_compaction: {:switched, {token, _retention}}} = s
      ) do
    OnlineCheckpoint.delete(s.online_snapshot)
    send(s.guardian, {:online_compaction_result, self(), token, {:ok, stats}})

    {:noreply,
     publish(Execution.wake_queues(%{s | online_compaction: nil, online_snapshot: nil})),
     {:continue, :release_transient_heap}}
  end

  def handle_info(
        {:compact_online_result, writer, token, {:error, reason}},
        %{writer: writer, online_compaction: {token, _retention}} = s
      ) do
    OnlineCheckpoint.delete(s.online_snapshot)
    send(s.guardian, {:online_compaction_result, self(), token, {:error, reason}})
    {:noreply, %{s | online_compaction: nil, online_snapshot: nil}}
  end

  def handle_info(
        {:lifecycle_drain, generation, token, guardian, expected_source},
        %{generation: generation, guardian: guardian} = s
      ) do
    s = flush_group_commit(s)

    if Tay.Engine.Operations.draining?(s.config.name, generation, token, guardian) do
      cond do
        not is_nil(expected_source) and s.mode != :ready ->
          send(guardian, {:operation_policy_draining, self(), token})
          {:noreply, s}

        not is_nil(expected_source) and expected_source != {s.epoch_id, s.next_sequence} ->
          send(guardian, {:operation_source_changed, self(), token})
          {:noreply, s}

        true ->
          next = %{s | mode: :draining, lifecycle_operation: token}
          hook(s.config, {:operations, :draining})
          {:noreply, publish(complete_drains(next))}
      end
    else
      {:noreply, s}
    end
  end

  def handle_info(
        {:lifecycle_compact, generation, token, guardian, deadline, retention, expected_source,
         cancel_flag},
        %{generation: generation, guardian: guardian, lifecycle_fenced: token, mode: :drained} =
          s
      ) do
    # Check estimates before drain, then allow legitimate settlement mutations.
    # Writer pins and replays the final frontier under its existing owner lock.
    result =
      if same_source_epoch?(expected_source, s.epoch_id),
        do:
          Writer.compact(
            s.writer,
            s.admission,
            deadline,
            retention,
            Clock.wall(s.config.clock),
            cancel_flag
          ),
        else: {:error, :compaction_source_changed}

    send(guardian, {:compaction_result, self(), token, result})
    {:noreply, s}
  end

  def handle_info({:policy_estimate, guardian, policy, token}, %{guardian: guardian} = s) do
    sealed_bytes = s.history_bytes - if(s.segment.state == :active, do: s.segment.bytes, else: 0)
    sealed_segments = s.segment_count - if(s.segment.state == :active, do: 1, else: 0)

    result =
      CompactionEstimate.summarize(
        s.compaction_estimate,
        sealed_bytes,
        sealed_segments,
        s.config.compaction.terminal_retention,
        Clock.wall(s.config.clock)
      )

    result =
      case result do
        {:ok, estimate} ->
          {:ok,
           Map.merge(estimate, %{
             last_compaction_at: s.last_compaction_at,
             checkpoint_events: s.events_since_checkpoint,
             generation: s.generation,
             source: {s.epoch_id, s.next_sequence}
           })}

        error ->
          error
      end

    send(guardian, {:policy_estimate_result, self(), policy, token, result})
    {:noreply, s}
  end

  def handle_info(
        {:policy_drain_cancel, generation, token, guardian},
        %{guardian: guardian, generation: generation} = s
      ) do
    if s.lifecycle_operation == token or s.lifecycle_fenced == token do
      {:noreply,
       Execution.wake_controls(%{
         s
         | mode: :ready,
           lifecycle_operation: nil,
           lifecycle_fenced: nil
       })}
    else
      {:noreply, s}
    end
  end

  # Protocol v1 connections and their capabilities are intentionally
  # generation-local.  They are never written to the job log: after a Tay
  # restart the durable task-ready index remains, but this pointer starts empty
  # until runtimes reconnect and advertise again.
  def handle_info({:executor_server_ready, server}, s) when is_pid(server) do
    {:noreply, Execution.wake_queues(%{s | executor_server: server})}
  end

  def handle_info({:executor_capacity_changed, server}, %{executor_server: server} = s) do
    {:noreply, Execution.wake_queues(s)}
  end

  def handle_info(
        {:executor_completion, server, reservation, result},
        %{executor_server: server} = s
      ) do
    key = {:executor, reservation}

    case Map.get(s.running, key) do
      %{kind: :external, reservation: ^reservation} = entry ->
        {:noreply, Execution.wake_controls(publish(Dispatcher.settle(s, key, entry, result)))}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:executor_timeout, reservation, execution}, s) do
    key = {:executor, reservation}

    case Map.get(s.running, key) do
      %{kind: :external, execution: ^execution} = entry ->
        if is_pid(entry.server), do: Dispatcher.cancel(entry.server, reservation)
        {:noreply, Execution.wake_controls(publish(Dispatcher.settle(s, key, entry, :timeout)))}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(
        {:execution_control, kind, pid, generation, token},
        %{generation: generation} = s
      ) do
    if Execution.control_member?(s, kind, pid) do
      s = %{
        s
        | controls: Map.put(s.controls, kind, pid),
          control_wakes: MapSet.delete(s.control_wakes, kind)
      }

      {s, delay} = Execution.control(kind, Execution.release_pending(s))
      Tay.Execution.Queue.acknowledged(pid, token, delay)
      {:noreply, publish(s)}
    else
      {:noreply, s}
    end
  end

  def handle_info(
        {:tay_execution, relay, ticket, generation, execution, message},
        %{generation: generation} = s
      ) do
    case Map.get(s.running, relay) do
      %{ticket: ^ticket} = entry ->
        if execution == entry.execution or (is_nil(execution) and not entry.released) do
          s = Execution.execution_message(s, relay, entry, message)
          {:noreply, Execution.wake_controls(publish(complete_drains(s)))}
        else
          {:noreply, s}
        end

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:DOWN, reference, :process, _relay, _}, s) do
    if Map.has_key?(s.relay_monitors, reference),
      do: {:stop, :execution_relay_lost, s},
      else: {:noreply, s}
  end

  def handle_info({:execution_snapshot_ack, token}, %{snapshot_pending: token} = s) do
    next = %{s | snapshot_pending: nil, snapshot_dirty: false}
    {:noreply, if(s.snapshot_dirty, do: publish(next), else: next)}
  end

  def handle_info({:drain_deadline, permit}, s) do
    case Map.pop(s.drainers, permit) do
      {nil, _} ->
        {:noreply, s}

      {{from, _timer}, drainers} ->
        next = %{s | drainers: drainers}
        reply_command(next, permit, from, {:error, Error.new(:timeout, :draining, nil, :drain)})
        {:noreply, next}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp flush_group_commit(s) do
    GroupCommit.flush(s, &command/2, &reply_command/4, &complete_drains/1)
  end

  defp submitted?(s, {slot, token}, {owner, _}) do
    with {:ok, meta} <- Admission.metadata(s.config.name),
         true <- meta.generation == s.generation and command_state?(meta.status),
         [{^slot, ^token, ^owner, :submitted, _}] <- :ets.lookup(s.config.name, slot),
         do: true,
         else: (_ -> false)
  end

  defp command_state?(%{state: state}) when state in [:ready, :draining, :drained], do: true

  defp command_state?(%{state: :compacting, phase: phase})
       when phase in [:preparing, :switching],
       do: true

  defp command_state?(_), do: false

  defp command(intent, state),
    do: Commands.execute(intent, state, &insert_new/5, &Execution.cancel_task/2)

  defp reply_command(s, {slot, token}, from, reply) do
    hook(s.config, :pre_reply)
    send(s.guardian, {:completed, self(), slot, token, from, reply, ProjectionState.snapshot(s)})
  end

  defp complete_drains(%{mode: :draining, settlement_reserve: 0, running: running} = s)
       when map_size(running) == 0 do
    next = %{
      s
      | mode: :drained,
        drainers: %{},
        lifecycle_operation: nil,
        lifecycle_fenced: s.lifecycle_operation || s.lifecycle_fenced
    }

    hook(s.config, {:operations, :drained})

    Enum.each(s.drainers, fn {permit, {from, timer}} ->
      Process.cancel_timer(timer)
      reply_command(next, permit, from, :ok)
    end)

    if s.lifecycle_operation,
      do: send(s.guardian, {:operation_drained, self(), s.lifecycle_operation})

    next
  end

  defp complete_drains(s), do: s

  defp acquire_local_fence(%{execution: false}, _guardian, _writer, _generation), do: :ok

  defp acquire_local_fence(_config, guardian, writer, generation) do
    runtime = GenServer.call(guardian, :runtime)
    store_id = Writer.status(writer).summary.store_id

    with {:ok, _} <- LocalFence.ensure_started(),
         {:ok, lease} <- LocalFence.acquire(store_id, generation, self(), guardian, runtime),
         do: GenServer.call(guardian, {:attach_fence, lease})
  end

  defp publish(%{snapshot_pending: nil} = s) do
    s = maybe_schedule_memory_reclaim(s)
    token = make_ref()
    send(s.guardian, {:execution_snapshot, self(), token, ProjectionState.snapshot(s)})
    %{s | snapshot_pending: token, snapshot_dirty: false}
  end

  defp publish(s) do
    s = maybe_schedule_memory_reclaim(s)
    %{s | snapshot_dirty: true}
  end

  defp maybe_schedule_memory_reclaim(
         %{
           active_budget: %{count: 0},
           running: running,
           memory_reclaim: nil,
           memory_reclaimed: false
         } = s
       )
       when map_size(running) == 0 do
    schedule_memory_reclaim(s)
  end

  defp maybe_schedule_memory_reclaim(s) do
    if s.active_budget.count > 0 or map_size(s.running) > 0 do
      case s.memory_reclaim do
        {timer, _token} ->
          Process.cancel_timer(timer)

        nil ->
          :ok
      end

      %{s | memory_reclaim: nil, memory_reclaimed: false}
    else
      s
    end
  end

  defp insert_new(s, raw, worker, bytes, durability) do
    c = s.config

    with {:ok, definition} <- Value.decode(bytes, c.value_limits),
         true <- V2.definition?(definition) || {:error, :invalid_definition},
         true <-
           valid_worker_mapping?(c, definition["worker_key"], worker) ||
             {:error, :worker_mapping},
         at = Clock.wall(c.clock),
         event = %Event{
           record_type: 1,
           data: %{
             "at" => at,
             "expected_revision" => 0,
             "job_id" => raw,
             "definition" => definition,
             "eligible_at" => definition["scheduled_at"] || at
           }
         },
         limits = %{
           c.value_limits
           | depth: c.insert_value_depth,
             output_nodes: c.insert_value_nodes
         },
         {:ok, {1, 1, payload}} <- Event.encode(event, limits, c.max_insert_payload_bytes),
         {:ok, _} <- Value.measure(definition["args"], limits, c.max_insert_args_bytes),
         {:ok, job, next} <-
           Persistence.commit(s, nil, event, {:durability, durability, payload}) do
      {{:ok, ProjectionState.view(next, job)}, next}
    else
      {:error, {:resource_limit, key}} ->
        failure(s, :capacity, key, raw)

      {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
        failure(s, :capacity, reason, raw)

      {:error, _} ->
        failure(s, :invalid, :insertion_validation, raw)
    end
  end

  defp valid_worker_mapping?(config, key, worker) do
    (Map.get(config.workers, key) == worker and not is_nil(worker)) or
      (external_enabled?(config) and worker == Tay.Executor.RemoteWorker and
         not Map.has_key?(config.workers, key))
  end

  defp external_enabled?(config),
    do: is_binary(config.executor_socket) or is_integer(config.http_port)

  defp failure(s, kind, reason, raw),
    do: {{:error, Error.new(kind, reason, JobID.encode(raw), :insert)}, s}

  defp schedule_memory_reclaim(%{memory_reclaim: nil} = s) do
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:reclaim_memory, token},
        @memory_reclaim_idle_ms
      )

    %{s | memory_reclaim: {timer, token}}
  end

  defp same_source_epoch?(nil, _epoch_id), do: true
  defp same_source_epoch?({epoch_id, _sequence}, epoch_id), do: true
  defp same_source_epoch?(_expected_source, _epoch_id), do: false

  defp startup_error(%Tay.Storage.Recovery.Error{} = error),
    do: Error.new(:unavailable, {:recovery, error})

  defp startup_error(reason)
       when reason in [
              :local_fence_lost,
              :local_fence_unavailable,
              :local_tasks_terminating,
              :local_generation_owned
            ],
       do: Error.new(:unavailable, reason)

  defp startup_error(_), do: Error.new(:unavailable, :recovery_failed)

  if Mix.env() == :test do
    defp hook(config, point) do
      if is_function(Map.get(config, :test_hook), 1), do: config.test_hook.(point)
      :ok
    end
  else
    defp hook(_config, _point), do: :ok
  end

  def terminate(_, s) do
    if Map.has_key?(s, :terminal_store), do: TerminalStore.close(s.terminal_store)
    if Process.alive?(s.writer), do: GenServer.stop(s.writer, :normal, :infinity)
    :ok
  end

  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_engine)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :generation_failed)
end
