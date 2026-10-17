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
    SchedulerIndex,
    TaskIndex,
    TerminalStore,
    Transition
  }

  alias Tay.Execution.{Clock, Outcome, Registry, Relay, LocalFence}
  alias Tay.Executor.Server
  alias Tay.HTTP.Listener, as: HTTPListener
  alias Tay.Storage.Writer
  alias Tay.Storage.V2.{Codec, Mutation}
  alias Tay.Storage.V2.Reducer, as: V2Reducer
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
         inspection = Writer.status(writer),
         {:ok, summary, candidate} <-
           Writer.activate_recovered(writer, inspection.session_ref),
         config = OnlineCheckpoint.recovered_config(config, summary),
         :ok <-
           GenServer.call(
             guardian,
             {:compaction_retention, self(), config.compaction.terminal_retention}
           ),
         {:ok, terminal_store} <- TerminalStore.open(config.name, config.data_dir, candidate.jobs) do
      if match?({:error, _}, activation_capability(summary)) do
        TerminalStore.close(terminal_store)
        GenServer.stop(writer)
        {:error, error} = activation_capability(summary)
        {:stop, error}
      else
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

        projection = Projection.new(dispatch_registry, config.queues, Map.get(config, :test_hook))
        hook(config, :indexes_created)
        projection = Projection.load(projection, active_jobs)
        true = Projection.valid?(projection)
        {active_budget, terminal_budget} = ProjectionState.partition_budgets(candidate.jobs)
        budget = candidate |> Transition.accounting() |> Map.merge(active_budget)
        # No copy of candidate.jobs survives init. Active jobs live in private
        # ETS; terminal history lives in a disposable disk projection. Startup
        # accounting reserves up to three charged active views.
        state = %{
          config: config,
          guardian: guardian,
          generation: generation,
          writer: writer,
          admission: summary.admission_ref,
          projection: projection,
          terminal_store: terminal_store,
          schedules: candidate.schedules,
          results: candidate.results,
          terminal_stats: ProjectionState.terminal_statistics(candidate.jobs),
          budget: budget,
          active_budget: active_budget,
          terminal_budget: terminal_budget,
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
          events_since_checkpoint:
            Map.get(summary, :checkpoint_tail_events, summary.record_count),
          store_id: summary.store_id,
          epoch_id: Map.get(summary, :epoch_id),
          next_availability_order: Map.get(candidate, :next_availability_order, 1),
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

        state = if config.execution, do: reconcile(state), else: state

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
    {:noreply, if(s.config.execution, do: start_controls(s), else: s)}
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
        {:insert, _, _, _}
        when s.config.durability == :sync and s.config.group_commit_interval_ms > 0 and
               s.mode == :ready ->
          {:noreply, GroupCommit.enqueue(s, permit, intent, from)}

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
          s = flush_group_commit(s)
          {reply, next} = command(intent, s)
          next = complete_drains(next)
          reply_command(next, permit, from, reply)
          {:noreply, wake_controls(next)}
      end
    else
      {:noreply, s}
    end
  end

  def handle_info({:flush_group_commit, token}, %{group_commit: %{token: token}} = s),
    do: {:noreply, s |> flush_group_commit() |> wake_controls()}

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
                {:noreply, %{next | online_compaction: token, online_snapshot: nil}}

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
        %{writer: writer, online_compaction: token} = s
      ) do
    s = flush_group_commit(s)
    send(s.guardian, {:online_compaction_switch_requested, self(), token})
    {:noreply, s}
  end

  def handle_info(
        {:online_compaction_switch_ack, guardian, token},
        %{guardian: guardian, online_compaction: token} = s
      ) do
    case Writer.finish_online_freeze(s.writer, s.admission, token) do
      :ok -> {:noreply, s}
      {:error, reason} -> exit({:online_compaction_freeze_failed, reason})
    end
  end

  def handle_info(
        {:compact_online_result, writer, token, {:ok, stats, false}},
        %{writer: writer, online_compaction: token} = s
      ) do
    OnlineCheckpoint.delete(s.online_snapshot)
    next = %{OnlineCheckpoint.adopt(s, stats) | online_snapshot: nil}
    send(s.guardian, {:online_compaction_result, self(), token, {:ok, stats}})
    {:noreply, publish(wake_queues(next)), {:continue, :release_transient_heap}}
  end

  def handle_info(
        {:compact_online_result, writer, token, {:ok, stats, true}},
        %{writer: writer, online_compaction: {:switched, token}} = s
      ) do
    OnlineCheckpoint.delete(s.online_snapshot)
    send(s.guardian, {:online_compaction_result, self(), token, {:ok, stats}})

    {:noreply, publish(wake_queues(%{s | online_compaction: nil, online_snapshot: nil})),
     {:continue, :release_transient_heap}}
  end

  def handle_info(
        {:compact_online_result, writer, token, {:error, reason}},
        %{writer: writer, online_compaction: token} = s
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
       wake_controls(%{s | mode: :ready, lifecycle_operation: nil, lifecycle_fenced: nil})}
    else
      {:noreply, s}
    end
  end

  # Protocol v1 connections and their capabilities are intentionally
  # generation-local.  They are never written to the job log: after a Tay
  # restart the durable task-ready index remains, but this pointer starts empty
  # until runtimes reconnect and advertise again.
  def handle_info({:executor_server_ready, server}, s) when is_pid(server) do
    {:noreply, wake_queues(%{s | executor_server: server})}
  end

  def handle_info({:executor_capacity_changed, server}, %{executor_server: server} = s) do
    {:noreply, wake_queues(s)}
  end

  def handle_info(
        {:executor_completion, server, reservation, result},
        %{executor_server: server} = s
      ) do
    key = {:executor, reservation}

    case Map.get(s.running, key) do
      %{kind: :external, reservation: ^reservation} = entry ->
        {:noreply, wake_controls(publish(settle_external(s, key, entry, result)))}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:executor_timeout, reservation, execution}, s) do
    key = {:executor, reservation}

    case Map.get(s.running, key) do
      %{kind: :external, execution: ^execution} = entry ->
        if is_pid(entry.server), do: safe_external_cancel(entry.server, reservation)
        {:noreply, wake_controls(publish(settle_external(s, key, entry, :timeout)))}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(
        {:execution_control, kind, pid, generation, token},
        %{generation: generation} = s
      ) do
    if control_member?(s, kind, pid) do
      s = %{
        s
        | controls: Map.put(s.controls, kind, pid),
          control_wakes: MapSet.delete(s.control_wakes, kind)
      }

      {s, delay} = control(kind, release_pending(s))
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
          s = execution_message(s, relay, entry, message)
          {:noreply, wake_controls(publish(complete_drains(s)))}
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
    do: Commands.execute(intent, state, &insert_new/4, &cancel_task/2)

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

  defp event(type, job, at, fields),
    do: %Event{
      record_type: type,
      data:
        Map.merge(%{"job_id" => job.id, "expected_revision" => job.revision, "at" => at}, fields)
    }

  defp acquire_local_fence(%{execution: false}, _guardian, _writer, _generation), do: :ok

  defp acquire_local_fence(_config, guardian, writer, generation) do
    runtime = GenServer.call(guardian, :runtime)
    store_id = Writer.status(writer).summary.store_id

    with {:ok, _} <- LocalFence.ensure_started(),
         {:ok, lease} <- LocalFence.acquire(store_id, generation, self(), guardian, runtime),
         do: GenServer.call(guardian, {:attach_fence, lease})
  end

  defp reconcile(s) do
    match = [{{:"$1", %{state: :executing}}, [], [true]}]
    count = :ets.select_count(s.projection.jobs, match)
    s = %{s | settlement_reserve: count}
    :ok = GenServer.call(s.guardian, {:reconciliation, ProjectionState.snapshot(s)})

    selection =
      :ets.select(
        s.projection.jobs,
        [{{:"$1", %{state: :executing}}, [], [:"$1"]}],
        s.config.execution_batch
      )

    reconcile_batch(s, selection)
  end

  defp reconcile_batch(s, :"$end_of_table"), do: s

  defp reconcile_batch(s, {ids, continuation}) do
    s =
      Enum.reduce(ids, s, fn id, acc ->
        job = JobIndex.get(acc.projection.jobs, id)
        {:ok, event} = Outcome.event(job, :interrupted, Clock.wall(acc.config.clock))

        case Persistence.commit(acc, job, event) do
          {:ok, _, next} -> next
          _ -> exit(:interrupted_settlement_failed)
        end
      end)

    hook(s.config, :reconciliation_batch)
    :ok = GenServer.call(s.guardian, {:reconciliation, ProjectionState.snapshot(s)})
    reconcile_batch(s, :ets.select(continuation))
  end

  defp start_controls(s) do
    supervisor = Tay.Execution.Supervisor.components(s.runtime).controls
    options = %{engine: self(), generation: s.generation, wake_ms: s.config.execution_wake_ms}

    {:ok, scheduler} =
      DynamicSupervisor.start_child(supervisor, {Tay.Execution.Scheduler, options})

    controls =
      Enum.reduce(s.config.queue_limits, %{scheduler: scheduler}, fn {queue, _}, acc ->
        kind = {:queue, queue}

        {:ok, pid} =
          DynamicSupervisor.start_child(
            supervisor,
            {Tay.Execution.Queue, Map.put(options, :kind, kind)}
          )

        Map.put(acc, kind, pid)
      end)

    # The executor server is generation-local; registration and reservations
    # are never durable. Either transport can keep it alive independently.
    executor_server =
      if s.config.executor_socket || s.config.http_port do
        {:ok, server} =
          DynamicSupervisor.start_child(
            supervisor,
            {Server,
             %{
               engine: self(),
               socket_path: s.config.executor_socket,
               socket_mode: s.config.executor_socket_mode,
               private_directory: s.config.executor_socket_private_directory,
               max_frame_bytes: s.config.executor_max_frame_bytes,
               max_connections: s.config.executor_max_connections,
               max_tasks_per_connection: s.config.executor_max_tasks_per_connection,
               result_bytes: s.config.executor_result_bytes,
               error_bytes: s.config.executor_error_bytes,
               max_results: s.config.executor_max_results,
               schedules: s.schedules,
               results: s.results,
               engine_name: s.config.name
             }}
          )

        server
      else
        nil
      end

    if s.config.http_port do
      {:ok, _listener} =
        DynamicSupervisor.start_child(
          supervisor,
          {HTTPListener,
           %{
             engine_name: s.config.name,
             executor_server: executor_server,
             port: s.config.http_port,
             ip: s.config.http_ip,
             max_body_bytes: s.config.http_max_body_bytes,
             result_bytes: s.config.executor_result_bytes,
             error_bytes: s.config.executor_error_bytes,
             tls_certfile: s.config.http_tls_certfile,
             tls_keyfile: s.config.http_tls_keyfile,
             tls_cacertfile: s.config.http_tls_cacertfile
           }}
        )
    end

    %{s | controls: controls, executor_server: executor_server}
  end

  defp control_member?(s, kind, pid) do
    valid_control_kind?(s, kind) and
      (Map.get(s.controls, kind) == pid or
         Enum.any?(
           DynamicSupervisor.which_children(
             Tay.Execution.Supervisor.components(s.runtime).controls
           ),
           fn {_, child, _, _} -> child == pid end
         ))
  end

  defp valid_control_kind?(_s, :scheduler), do: true

  defp valid_control_kind?(s, {:queue, queue}),
    do: Map.has_key?(s.config.queue_limits, queue)

  defp valid_control_kind?(_s, _kind), do: false

  defp control(_kind, %{mode: mode} = s) when mode != :ready,
    do: {s, s.config.execution_wake_ms}

  defp control(:scheduler, s) do
    at = Clock.wall(s.config.clock)
    ids = SchedulerIndex.due(s.projection.schedule, at, s.config.execution_batch)

    {s, refused} =
      Enum.reduce_while(ids, {s, false}, fn id, {acc, _} ->
        job = JobIndex.get(acc.projection.jobs, id)
        at = Clock.wall(acc.config.clock)

        if job.eligible_at <= at do
          case Persistence.commit(acc, job, event(2, job, at, %{"due_at" => job.eligible_at})) do
            {:ok, _, next} -> {:cont, {next, false}}
            {:error, _} -> {:halt, {acc, true}}
          end
        else
          {:halt, {acc, false}}
        end
      end)

    due = SchedulerIndex.earliest(s.projection.schedule)
    # A capacity refusal must not turn a due head into a busy loop.
    delay =
      if due && not refused,
        do: Clock.delay_until(due, Clock.wall(s.config.clock), s.config.execution_wake_ms),
        else: s.config.execution_wake_ms

    {wake_queues(s), delay}
  end

  defp control({:queue, queue}, s) do
    if not MapSet.member?(s.paused, queue) and s.slots[queue] < s.config.queue_limits[queue] do
      case next_ready(s, queue, Clock.wall(s.config.clock)) do
        {:ok, job} ->
          case claim(s, job, queue) do
            {:ok, next} -> {next, 0}
            {:error, next} -> {next, s.config.execution_wake_ms}
          end

        :none ->
          {s, s.config.execution_wake_ms}
      end
    else
      {s, s.config.execution_wake_ms}
    end
  end

  # Pick the oldest ready job *among capabilities with current capacity*.
  # Querying the task index per advertised capability is bounded by the server
  # connection/task limits, and means an absent PHP executor cannot hide a
  # later Python task at the head of a shared queue.
  defp next_ready(s, queue, now) do
    local = Map.keys(s.projection.registry)

    external =
      if is_pid(s.executor_server) and Process.alive?(s.executor_server),
        do: Server.available_tasks(s.executor_server),
        else: []

    candidates =
      (local ++ external)
      |> Enum.uniq()
      |> Enum.flat_map(fn task ->
        case TaskIndex.ready(s.projection.task, queue, task, now, 1) do
          [id] ->
            case JobIndex.get(s.projection.jobs, id) do
              nil -> []
              job -> [job]
            end

          [] ->
            []
        end
      end)

    case candidates do
      [] -> :none
      jobs -> {:ok, Enum.min_by(jobs, &TaskIndex.key/1)}
    end
  catch
    :exit, _ -> :none
  end

  defp claim(s, job, queue) do
    at = Clock.wall(s.config.clock)
    started = event(3, job, at, %{"attempt" => job.next_attempt, "cycle_token" => job.cycle})

    with {:ok, dispatch} <- dispatch_for(s, job),
         true <- not MapSet.member?(s.projection.held, job.id),
         {:ok, predicted} <- predict_execution(s, job, started),
         :ok <- settlement_fits(s, predicted, at),
         {:ok, {_, _, payload}} <- execution_encoding(s, job, started),
         :ok <- Persistence.headroom(s, byte_size(payload), s.settlement_reserve + 1) do
      case dispatch do
        {:local, worker} ->
          options = %{
            engine: self(),
            guardian: s.guardian,
            generation: s.generation,
            worker: worker,
            timeout_ms: job.definition["timeout_ms"],
            clock: s.config.clock,
            eligible_at: job.eligible_at,
            test_terminate: test_terminate_option(s.config)
          }

          case Tay.Execution.Supervisor.prepare(s.runtime, options) do
            {:ok, identity} -> start_waiting(s, job, queue, identity)
            _ -> exit(:execution_start_failed)
          end

        {:external, server, reservation} ->
          start_external(s, job, queue, started, server, reservation)
      end
    else
      _ -> {:error, s}
    end
  end

  defp dispatch_for(s, job) do
    case Registry.resolve(s.config.workers, job.definition["worker_key"]) do
      {:ok, worker} ->
        {:ok, {:local, worker}}

      _ when is_pid(s.executor_server) ->
        case Server.reserve(
               s.executor_server,
               job.definition["worker_key"],
               job.definition["queue_key"]
             ) do
          {:ok, reservation} -> {:ok, {:external, s.executor_server, reservation}}
          _ -> {:error, :no_executor_capacity}
        end

      _ ->
        {:error, :unavailable_worker}
    end
  catch
    :exit, _ -> {:error, :no_executor_capacity}
  end

  defp settlement_fits(s, executing, at) do
    Enum.reduce_while([:success, {:failure, 1}, :timeout, :interrupted], :ok, fn outcome, _ ->
      with {:ok, finished} <- Outcome.event(executing, outcome, at, fn 2 -> <<0, 0>> end),
           {:ok, _} <- execution_encoding(s, executing, finished),
           {:ok, _} <- prepare_settlement(s, executing, finished) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :settlement_budget}}
      end
    end)
  end

  defp predict_execution(%{epoch_id: epoch} = s, job, event) when is_binary(epoch),
    do: prepare_settlement(s, job, event)

  defp predict_execution(s, job, event) do
    with {:ok, prepared} <- Transition.prepare(job, event, s.config.value_limits),
         do: Transition.apply(prepared, %{sequence: s.next_sequence})
  end

  defp execution_encoding(%{epoch_id: epoch} = s, job, event) when is_binary(epoch) do
    with {:ok, mutation} <- Mutation.from_event(event, job, s.next_availability_order),
         {:ok, payload} <- Codec.encode_mutation(mutation, s.config.value_limits),
         do: {:ok, {8, 1, payload}}
  end

  defp execution_encoding(s, _job, event), do: Persistence.encoded_event(s, event, nil)

  defp prepare_settlement(%{epoch_id: epoch} = s, job, event) when is_binary(epoch) do
    with {:ok, mutation} <- Mutation.from_event(event, job, s.next_availability_order),
         {:ok, predicted, _} <-
           V2Reducer.apply_one(
             job,
             mutation,
             s.next_availability_order,
             s.config.candidate_limits,
             s.config.value_limits
           ),
         do: {:ok, predicted}
  end

  defp prepare_settlement(s, job, event),
    do: Transition.prepare(job, event, s.config.value_limits)

  defp start_waiting(s, job, queue, identity) do
    monitor = Process.monitor(identity.relay)

    entry =
      Map.merge(identity, %{
        id: job.id,
        queue: queue,
        eligible_at: job.eligible_at,
        execution: nil,
        released: false,
        settled: false,
        dead: false,
        monitor: monitor
      })

    s = %{
      s
      | running: Map.put(s.running, identity.relay, entry),
        executions: Map.put(s.executions, job.id, identity.relay),
        relay_monitors: Map.put(s.relay_monitors, monitor, identity.relay),
        slots: Map.update!(s.slots, queue, &(&1 + 1)),
        projection: Projection.hold(s.projection, job)
    }

    hook(s.config, {:execution, :task_waiting})
    at = Clock.wall(s.config.clock)

    if Process.alive?(identity.task) and at >= job.eligible_at do
      started = event(3, job, at, %{"attempt" => job.next_attempt, "cycle_token" => job.cycle})

      case Persistence.commit(s, job, started) do
        {:ok, executing, next} ->
          entry = %{entry | execution: executing.execution}
          next = %{next | running: Map.put(next.running, identity.relay, entry)}
          {:ok, release_pending(next)}

        {:error, _} ->
          {:error, abandon_waiting(s, identity.relay)}
      end
    else
      {:error, abandon_waiting(s, identity.relay)}
    end
  end

  # Remote executors are not BEAM tasks and must never be put behind the local
  # relay/fence protocol.  Reserve an advertised connection first, make the
  # existing durable START transition, then send EXECUTE.  A process crash in
  # any later window is reconciled through the normal `:executing` recovery
  # path, giving the documented at-least-once behaviour.
  defp start_external(s, job, queue, started, server, reservation) do
    case Persistence.commit(s, job, started) do
      {:ok, executing, next} ->
        key = {:executor, reservation}

        timer =
          Process.send_after(
            self(),
            {:executor_timeout, reservation, executing.execution},
            job.definition["timeout_ms"]
          )

        entry = %{
          kind: :external,
          id: job.id,
          queue: queue,
          execution: executing.execution,
          reservation: reservation,
          server: server,
          timer: timer
        }

        next = %{
          next
          | running: Map.put(next.running, key, entry),
            executions: Map.put(next.executions, job.id, key),
            slots: Map.update!(next.slots, queue, &(&1 + 1)),
            projection: Projection.hold(next.projection, job)
        }

        # The server only serializes JSON-compatible fields from this view and
        # preserves the reservation until completion/disconnect.  It cannot
        # send an execution before this durable START exists.
        case safe_external_dispatch(server, reservation, ProjectionState.view(next, executing)) do
          :ok -> {:ok, next}
          _ -> {:error, settle_external(next, key, entry, :lost)}
        end

      {:error, _} ->
        safe_external_release(server, reservation)
        {:error, s}
    end
  end

  defp abandon_waiting(s, relay) do
    entry = s.running[relay]
    :ok = Relay.terminate_task(relay, entry.ticket)
    %{s | running: Map.put(s.running, relay, %{entry | settled: true})}
  end

  defp release_pending(s) do
    Enum.reduce(s.running, s, fn {relay, entry}, acc ->
      if (Map.get(entry, :kind) != :external and
            (not entry.released and not entry.settled and entry.execution)) &&
           Clock.wall(acc.config.clock) >= entry.eligible_at do
        hook(acc.config, {:execution, :pre_release})
        # Recheck after a fault barrier as well as after storage latency.
        if Clock.wall(acc.config.clock) >= entry.eligible_at do
          job = JobIndex.get(acc.projection.jobs, entry.id)

          case Relay.release(relay, entry.ticket, entry.execution, ProjectionState.view(acc, job)) do
            :ok ->
              hook(acc.config, {:execution, :released})
              %{acc | running: Map.put(acc.running, relay, %{entry | released: true})}

            _ ->
              exit(:execution_release_failed)
          end
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp execution_message(s, relay, entry, {:outcome, outcome}) do
    job = JobIndex.get(s.projection.jobs, entry.id)

    if not entry.settled and entry.released and job.state == :executing and
         job.execution == entry.execution and job.revision == entry.execution do
      {:ok, finished} = Outcome.event(job, outcome, Clock.wall(s.config.clock))

      case Persistence.commit(s, job, finished) do
        {:ok, _, next} ->
          :ok = Relay.settled(relay, entry.ticket)

          finish_runtime(
            %{next | running: Map.put(next.running, relay, %{entry | settled: true})},
            relay
          )

        _ ->
          exit(:execution_settlement_failed)
      end
    else
      s
    end
  end

  defp execution_message(s, relay, entry, :dead) do
    hook(s.config, {:execution, :task_dead})

    if entry.execution != nil and not entry.released and not entry.settled,
      do: exit(:execution_release_failed)

    finish_runtime(%{s | running: Map.put(s.running, relay, %{entry | dead: true})}, relay)
  end

  defp execution_message(s, _relay, _entry, _), do: s

  defp cancel_task(s, id) do
    case Map.get(s.executions, id) do
      nil ->
        s

      {:executor, reservation} = key ->
        case Map.get(s.running, key) do
          %{kind: :external} = entry ->
            if is_pid(entry.server), do: safe_external_cancel(entry.server, reservation)
            settle_external(s, key, entry, :cancelled)

          _ ->
            s
        end

      relay ->
        entry = s.running[relay]
        :ok = Relay.terminate_task(relay, entry.ticket)
        finish_runtime(%{s | running: Map.put(s.running, relay, %{entry | settled: true})}, relay)
    end
  end

  defp finish_runtime(s, relay) do
    case s.running[relay] do
      %{settled: true, dead: true} = entry ->
        Process.demonitor(entry.monitor, [:flush])
        job = JobIndex.get(s.projection.jobs, entry.id)

        %{
          s
          | running: Map.delete(s.running, relay),
            executions: Map.delete(s.executions, entry.id),
            relay_monitors: Map.delete(s.relay_monitors, entry.monitor),
            slots: Map.update!(s.slots, entry.queue, &(&1 - 1)),
            projection: Projection.release(s.projection, job, entry.id)
        }

      _ ->
        s
    end
  end

  defp settle_external(s, key, entry, result) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    job = JobIndex.get(s.projection.jobs, entry.id)

    s =
      case {result, job} do
        {:cancelled, _} ->
          s

        {_, %{state: :executing, execution: execution}} when execution == entry.execution ->
          outcome = external_outcome(result)

          case Outcome.event(job, outcome, Clock.wall(s.config.clock)) do
            {:ok, finished} ->
              case Persistence.commit(s, job, finished) do
                {:ok, completed, next} -> persist_external_result(next, completed, result)
                _ -> exit(:external_execution_settlement_failed)
              end

            _ ->
              exit(:external_execution_outcome_invalid)
          end

        _ ->
          s
      end

    if is_pid(entry.server), do: safe_external_release(entry.server, entry.reservation)

    %{
      s
      | running: Map.delete(s.running, key),
        executions: Map.delete(s.executions, entry.id),
        slots: Map.update!(s.slots, entry.queue, &max(&1 - 1, 0)),
        projection: if(job, do: Projection.release(s.projection, job), else: s.projection)
    }
  end

  defp external_outcome(:success), do: :success
  defp external_outcome({:success, _result}), do: :success
  defp external_outcome(:timeout), do: :timeout
  defp external_outcome(:lost), do: :interrupted
  defp external_outcome({:failure, _}), do: {:failure, 1}
  defp external_outcome(_), do: {:failure, 1}

  defp persist_external_result(state, completed, {:success, result}) do
    event = %Event{
      record_type: 10,
      payload_schema_version: 2,
      data: %{
        "at" => completed.completed_at,
        "expected_revision" => completed.revision,
        "job_id" => completed.id,
        "result" => result
      }
    }

    case Persistence.commit_auxiliary(state, event, completed) do
      {:ok, next} -> next
      _ -> exit(:external_result_commit_failed)
    end
  end

  defp persist_external_result(state, _completed, _result), do: state

  defp safe_external_dispatch(server, reservation, job) do
    Server.dispatch(server, reservation, job)
  catch
    :exit, _ -> {:error, :executor_unavailable}
  end

  defp safe_external_release(server, reservation) do
    Server.release(server, reservation)
  catch
    :exit, _ -> :ok
  end

  defp safe_external_cancel(server, reservation) do
    Server.cancel(server, reservation)
  catch
    :exit, _ -> :ok
  end

  defp wake_controls(s) do
    Enum.reduce(s.controls, s, fn {kind, pid}, acc -> wake_control(acc, kind, pid) end)
  end

  defp wake_queues(s) do
    Enum.reduce(s.controls, s, fn
      {{:queue, _} = kind, pid}, acc -> wake_control(acc, kind, pid)
      _, acc -> acc
    end)
  end

  defp wake_control(s, kind, pid) do
    if MapSet.member?(s.control_wakes, kind) do
      s
    else
      Tay.Execution.Queue.wake(pid)
      %{s | control_wakes: MapSet.put(s.control_wakes, kind)}
    end
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

  defp insert_new(s, raw, worker, bytes) do
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
         {:ok, job, next} <- Persistence.commit(s, nil, event, payload) do
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
    defp test_terminate_option(config), do: Map.get(config, :test_terminate)

    defp hook(config, point) do
      if is_function(Map.get(config, :test_hook), 1), do: config.test_hook.(point)
      :ok
    end
  else
    defp test_terminate_option(_config), do: nil
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
