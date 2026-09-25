defmodule Tay.Engine do
  @moduledoc """
  One generation's semantic command owner and sole private-index owner.
  The log is authoritative. Live producers use the same pure Event transition
  model as recovery; callback execution never runs in this process.
  """
  use GenServer, restart: :temporary
  alias Tay.{Event, Error, Job, JobID, Queue}
  alias Tay.Event.{V1, Value}
  alias Tay.Engine.{Admission, Config, CompactionEstimate, CompactionReplay}

  alias Tay.State.{
    CombinedInspection,
    InspectionIndex,
    JobIndex,
    Projection,
    SchedulerIndex,
    TaskIndex,
    TerminalStore,
    Transition
  }

  alias Tay.Execution.{Clock, Outcome, Registry, Relay, LocalFence}
  alias Tay.Executor.Server
  alias Tay.Storage.{Writer, Segment}
  alias Tay.Storage.V2.{Codec, V1Migration}
  alias Tay.Storage.V2.Reducer, as: V2Reducer
  @segment_catalog_limit 128
  @states [:available, :scheduled, :executing, :retryable, :completed, :cancelled, :discarded]

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

        active_jobs = Map.reject(candidate.jobs, fn {_id, job} -> terminal?(job) end)
        projection = Projection.new(dispatch_registry, config.queues, Map.get(config, :test_hook))
        hook(config, :indexes_created)
        projection = Projection.load(projection, active_jobs)
        true = Projection.valid?(projection)
        {active_budget, terminal_budget} = partition_budgets(candidate.jobs)
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
          terminal_stats: terminal_statistics(candidate.jobs),
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
          history_bytes:
            summary.total_segment_bytes +
              44 * (summary.highest.id - inspection.summary.highest.id),
          segment_count:
            summary.segment_count + summary.highest.id - inspection.summary.highest.id,
          definition_bytes:
            Enum.reduce(candidate.jobs, 0, fn {_id, job}, n ->
              n + byte_size(job.definition_bytes)
            end),
          blocked:
            JobIndex.fold(
              projection.jobs,
              fn job, n ->
                if (not Map.has_key?(dispatch_registry, job.definition["worker_key"]) and
                      not external_enabled?(config)) or
                     not Map.has_key?(config.queues, job.definition["queue_key"]),
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
            :ok = GenServer.call(guardian, {:ready, snapshot(state)})
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
    {:noreply, if(s.config.execution, do: start_controls(s), else: s)}
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
      ensure_generation_live!(s)

      case intent do
        {:drain, deadline} when is_integer(deadline) ->
          timer =
            Process.send_after(
              self(),
              {:drain_deadline, permit},
              max(deadline - System.monotonic_time(:millisecond), 0)
            )

          next = %{s | mode: :draining, drainers: Map.put(s.drainers, permit, {from, timer})}
          hook(s.config, {:operations, :draining})
          {:noreply, publish(complete_drains(next))}

        _ ->
          {reply, next} = command(intent, s)
          next = complete_drains(next)
          reply_command(next, permit, from, reply)
          {:noreply, wake_controls(next)}
      end
    else
      {:noreply, s}
    end
  end

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
        {:lifecycle_drain, generation, token, guardian, expected_source},
        %{generation: generation, guardian: guardian} = s
      ) do
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
      if is_nil(expected_source) or elem(expected_source, 0) == s.epoch_id,
        do:
          Writer.compact(
            s.writer,
            s.admission,
            deadline,
            retention,
            Clock.wall(s.config.clock),
            compaction_terminal_limit(s),
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
        s.config.compaction.max_terminal_jobs,
        Clock.wall(s.config.clock)
      )

    result =
      case result do
        {:ok, estimate} ->
          {:ok,
           Map.merge(estimate, %{
             last_compaction_at: s.last_compaction_at,
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

  defp submitted?(s, {slot, token}, {owner, _}) do
    with {:ok, meta} <- Admission.metadata(s.config.name),
         true <-
           meta.generation == s.generation and meta.status.state in [:ready, :draining, :drained],
         [{^slot, ^token, ^owner, :submitted, _}] <- :ets.lookup(s.config.name, slot),
         do: true,
         else: (_ -> false)
  end

  defp command({:get, raw}, s) do
    result =
      case lookup_job(s, raw) do
        nil -> {:error, :not_found}
        job -> {:ok, view(s, job)}
      end

    {result, s}
  end

  defp command({:inspect_jobs, query}, s) do
    page = CombinedInspection.page(s.projection.jobs, s.terminal_store, query)
    {{:ok, %{page | jobs: Enum.map(page.jobs, &view(s, &1))}}, s}
  end

  defp command(:inspect_stats, s) do
    stats =
      Map.merge(s.terminal_stats.states, InspectionIndex.stats(s.projection.inspection), fn
        _state, cold, hot -> cold + hot
      end)

    {{:ok, stats}, s}
  end

  defp command(:inspect_queues, s) do
    queues =
      s.config.queues
      |> Enum.map(fn {key, name} ->
        %Queue{
          key: key,
          name: name,
          paused: MapSet.member?(s.paused, key),
          concurrency: Map.fetch!(s.config.queue_limits, key),
          executing: Map.get(s.slots, key, 0),
          jobs:
            InspectionIndex.queue_count(s.projection.inspection, key) +
              (get_in(s.terminal_stats, [:queues, key, :count]) || 0),
          states:
            (get_in(s.terminal_stats, [:queues, key, :states]) || zero_states())
            |> Map.merge(InspectionIndex.queue_stats(s.projection.inspection, key), fn
              _state, cold, hot -> cold + hot
            end)
        }
      end)
      |> Enum.sort_by(& &1.key)

    {{:ok, queues}, s}
  end

  defp command({:insert, raw, worker, bytes}, s) do
    existing = lookup_job(s, raw)

    cond do
      existing && existing.definition_bytes == bytes -> {{:ok, view(s, existing)}, s}
      existing -> failure(s, :invalid, :id_conflict, raw)
      s.mode != :ready -> failure(s, :unavailable, :draining, raw)
      true -> insert_new(s, raw, worker, bytes)
    end
  end

  defp command({operation, queue}, s) when operation in [:pause_queue, :resume_queue] do
    if Map.has_key?(s.config.queues, queue) do
      paused =
        if operation == :pause_queue,
          do: MapSet.put(s.paused, queue),
          else: MapSet.delete(s.paused, queue)

      next = %{s | paused: paused}
      hook(s.config, {:operations, operation})
      Tay.Telemetry.queue_control(s.config.name, operation, queue)
      {:ok, next}
    else
      {{:error, Error.new(:invalid, :unknown_queue, nil, operation)}, s}
    end
  end

  defp command({operation, raw, revision}, s) when operation in [:cancel, :retry] do
    job = lookup_job(s, raw)

    cond do
      lifecycle_barrier?(s) ->
        mutation_failure(s, operation, raw, revision, :unavailable, :generation_stopping)

      is_nil(job) ->
        {{:error, :not_found}, s}

      revision != view(s, job).revision ->
        mutation_failure(s, operation, raw, revision, :conflict, :revision_conflict)

      operation == :cancel and job.state == :cancelled ->
        {{:ok, view(s, job)}, s}

      operation == :cancel and job.state in [:completed, :discarded] ->
        mutation_failure(s, operation, raw, revision, :conflict, :terminal_state)

      operation == :retry and job.state not in [:retryable, :discarded] ->
        mutation_failure(s, operation, raw, revision, :conflict, :state_conflict)

      true ->
        at = Clock.wall(s.config.clock)
        event = mutation_event(operation, job, at)

        case commit(s, job, event) do
          {:ok, next_job, next} ->
            next = if operation == :cancel, do: cancel_task(next, raw), else: next
            {{:ok, view(next, next_job)}, next}

          {:error, reason} ->
            mutation_failure(s, operation, raw, revision, :capacity, bounded_commit_error(reason))
        end
    end
  end

  defp command(_, s), do: {{:error, Error.new(:invalid, :invalid_request)}, s}

  defp reply_command(s, {slot, token}, from, reply) do
    hook(s.config, :pre_reply)
    send(s.guardian, {:completed, self(), slot, token, from, reply, snapshot(s)})
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

  # Once a lifecycle drain acknowledges quiescence, a queued administrative
  # producer cannot open a new append window before Guardian closes the group.
  # A timed-out/aborted operation releases its exact row: ordinary drained-state
  # administration remains possible, without undoing drain or reviving claims.
  defp lifecycle_barrier?(%{lifecycle_fenced: nil}), do: false

  defp lifecycle_barrier?(s) do
    token = s.lifecycle_fenced

    with {:ok, meta} <- Admission.metadata(s.config.name),
         true <- meta.generation == s.generation,
         [{:operation, ^token, _, stage, _}] when stage in [:submitted, :closing, :starting] <-
           :ets.lookup(s.config.name, :operation),
         do: true,
         else: (_ -> false)
  end

  defp mutation_event(:cancel, job, at),
    do: event(5, job, at, %{"execution_token" => job.execution})

  defp mutation_event(:retry, job, at),
    do:
      event(6, job, at, %{
        "mode" => if(job.state == :discarded, do: 1, else: 0),
        "new_due_at" => at
      })

  defp mutation_failure(s, operation, raw, revision, kind, reason),
    do: {{:error, Error.new(kind, reason, JobID.encode(raw), operation, revision)}, s}

  defp bounded_commit_error({:resource_limit, key}), do: key

  defp bounded_commit_error(reason) when reason in [:sequence_exhausted, :segment_id_exhausted],
    do: reason

  defp bounded_commit_error(_), do: :event_budget

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
    :ok = GenServer.call(s.guardian, {:reconciliation, snapshot(s)})

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

        case commit(acc, job, event) do
          {:ok, _, next} -> next
          _ -> exit(:interrupted_settlement_failed)
        end
      end)

    hook(s.config, :reconciliation_batch)
    :ok = GenServer.call(s.guardian, {:reconciliation, snapshot(s)})
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

    # The listener is a runtime child, not a foundation child: it is torn down
    # with this Engine generation and stale Unix socket state is therefore not
    # durable ownership. Passing `executor_socket: nil` explicitly remains the
    # opt-out for a BEAM-only Engine; otherwise Config resolves a local path.
    if s.config.executor_socket do
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
             engine_name: s.config.name
           }}
        )

      %{s | controls: controls, executor_server: server}
    else
      %{s | controls: controls}
    end
  end

  defp control_member?(s, kind, pid) do
    valid_kind =
      kind == :scheduler or
        (match?({:queue, _}, kind) and Map.has_key?(s.config.queue_limits, elem(kind, 1)))

    valid_kind and
      (Map.get(s.controls, kind) == pid or
         Enum.any?(
           DynamicSupervisor.which_children(
             Tay.Execution.Supervisor.components(s.runtime).controls
           ),
           fn {_, child, _, _} -> child == pid end
         ))
  end

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
          case commit(acc, job, event(2, job, at, %{"due_at" => job.eligible_at})) do
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
         :ok <- headroom(s, byte_size(payload), s.settlement_reserve + 1) do
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
        case Server.reserve(s.executor_server, job.definition["worker_key"]) do
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
    with {:ok, mutation} <- V1Migration.translate_event(event, job, s.next_availability_order),
         {:ok, payload} <- Codec.encode_mutation(mutation, s.config.value_limits),
         do: {:ok, {8, 1, payload}}
  end

  defp execution_encoding(s, _job, event), do: encoded_event(s, event, nil)

  defp prepare_settlement(%{epoch_id: epoch} = s, job, event) when is_binary(epoch) do
    with {:ok, mutation} <- V1Migration.translate_event(event, job, s.next_availability_order),
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

      case commit(s, job, started) do
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
    case commit(s, job, started) do
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
        case safe_external_dispatch(server, reservation, view(next, executing)) do
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

          case Relay.release(relay, entry.ticket, entry.execution, view(acc, job)) do
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

      case commit(s, job, finished) do
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
              case commit(s, job, finished) do
                {:ok, _, next} -> next
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
    token = make_ref()
    send(s.guardian, {:execution_snapshot, self(), token, snapshot(s)})
    %{s | snapshot_pending: token, snapshot_dirty: false}
  end

  defp publish(s), do: %{s | snapshot_dirty: true}

  defp insert_new(s, raw, worker, bytes) do
    c = s.config

    with {:ok, definition} <- Value.decode(bytes, c.value_limits),
         true <- V1.definition?(definition) || {:error, :invalid_definition},
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
         {:ok, job, next} <- commit(s, nil, event, payload) do
      next = %{next | blocked: s.blocked + if(blocked?(s, job), do: 1, else: 0)}
      {{:ok, view(next, job)}, next}
    else
      {:error, {:resource_limit, key}} ->
        failure(s, :capacity, key, raw)

      {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
        failure(s, :capacity, reason, raw)

      {:error, _} ->
        failure(s, :invalid, :insertion_validation, raw)
    end
  end

  # One commit path for every producer. All semantic/capacity checks precede
  # Writer I/O; any failure after it may have committed revokes the generation.
  defp commit(s, previous, event, encoded \\ nil)

  defp commit(%{epoch_id: epoch_id} = s, previous, event, _encoded)
       when is_binary(epoch_id),
       do: commit_v2(s, previous, event)

  defp commit(s, previous, event, encoded) do
    ensure_generation_live!(s)

    with {:ok, {type, schema, payload}} <- encoded_event(s, event, encoded),
         {:ok, effect} <- Transition.prepare(previous, event, s.config.value_limits),
         reserve = reservation_after(s, previous, type),
         :ok <- headroom(s, byte_size(payload), reserve),
         {:ok, predicted} <- Transition.apply(effect, %{sequence: s.next_sequence}),
         {:ok, _, budget} <- account_active(s, previous, predicted) do
      hook(s.config, {:execution, type, :pre_append})
      hook(s.config, :pre_append)

      case Writer.append(s.writer, s.admission, type, schema, payload) do
        {:ok, receipt} ->
          expected = expected_position(s, byte_size(payload))

          if receipt != Map.put(expected, :durability, s.config.durability),
            do: exit(:invalid_writer_receipt)

          hook(s.config, :post_append)
          hook(s.config, {:execution, type, :post_append})
          {:ok, job} = Transition.apply(effect, receipt)
          {:ok, job, ^budget} = account_active(s, previous, job)

          job =
            Map.put(job, :terminal_at, CompactionEstimate.terminal_time(job, event.data["at"]))

          :ok = publish_projection(s, previous, job)
          Tay.Telemetry.transition(s.config.name, telemetry_operation(type), previous, job)

          next = %{
            s
            | budget: budget,
              active_budget: replace_partition(s.active_budget, previous, job, :active),
              terminal_budget: replace_partition(s.terminal_budget, previous, job, :terminal),
              terminal_stats: replace_terminal_stats(s.terminal_stats, previous, job),
              compaction_estimate:
                CompactionEstimate.replace(s.compaction_estimate, previous, job),
              next_sequence: s.next_sequence + 1,
              settlement_reserve: reserve,
              history_bytes: s.history_bytes + history_delta(s, byte_size(payload)),
              segment_count: s.segment_count + receipt.segment_id - s.segment.id,
              definition_bytes:
                s.definition_bytes +
                  if(is_nil(previous), do: byte_size(job.definition_bytes), else: 0),
              segment: %{
                id: receipt.segment_id,
                state: :active,
                bytes: receipt.offset + byte_size(payload) + 28,
                count: if(receipt.segment_id == s.segment.id, do: s.segment.count + 1, else: 1)
              },
              segment_catalog: update_segment_catalog(s, receipt, byte_size(payload))
          }

          notify_terminal_pressure(next)

          hook(s.config, :post_projection)
          hook(s.config, {:execution, type, :post_projection})
          {:ok, job, next}

        {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
          {:error, reason}

        _ ->
          exit(:writer_commit_unknown)
      end
    end
  end

  defp commit_v2(s, previous, event) do
    ensure_generation_live!(s)

    with {:ok, mutation} <-
           V1Migration.translate_event(event, previous, s.next_availability_order),
         {:ok, payload} <- Codec.encode_mutation(mutation, s.config.value_limits),
         {:ok, predicted, next_order} <-
           V2Reducer.apply_one(
             previous,
             mutation,
             s.next_availability_order,
             s.config.candidate_limits,
             s.config.value_limits
           ),
         reserve = reservation_after(s, previous, event.record_type),
         :ok <- headroom(s, byte_size(payload), reserve),
         {:ok, job, budget} <- account_active(s, previous, predicted) do
      hook(s.config, {:execution, 8, :pre_append})
      hook(s.config, :pre_append)

      case Writer.append(s.writer, s.admission, 8, 1, payload) do
        {:ok, receipt} ->
          expected = expected_position(s, byte_size(payload))

          if receipt != Map.put(expected, :durability, s.config.durability),
            do: exit(:invalid_writer_receipt)

          hook(s.config, :post_append)
          hook(s.config, {:execution, 8, :post_append})
          :ok = publish_projection(s, previous, job)

          Tay.Telemetry.transition(
            s.config.name,
            telemetry_operation(event.record_type),
            previous,
            job
          )

          next = %{
            s
            | budget: budget,
              active_budget: replace_partition(s.active_budget, previous, job, :active),
              terminal_budget: replace_partition(s.terminal_budget, previous, job, :terminal),
              terminal_stats: replace_terminal_stats(s.terminal_stats, previous, job),
              compaction_estimate:
                CompactionEstimate.replace(s.compaction_estimate, previous, job),
              next_sequence: s.next_sequence + 1,
              next_availability_order: next_order,
              settlement_reserve: reserve,
              history_bytes: s.history_bytes + history_delta(s, byte_size(payload)),
              segment_count: s.segment_count + receipt.segment_id - s.segment.id,
              definition_bytes:
                s.definition_bytes +
                  if(is_nil(previous), do: byte_size(job.definition_bytes), else: 0),
              segment: %{
                id: receipt.segment_id,
                state: :active,
                bytes: receipt.offset + byte_size(payload) + 28,
                count: if(receipt.segment_id == s.segment.id, do: s.segment.count + 1, else: 1)
              },
              segment_catalog: update_segment_catalog(s, receipt, byte_size(payload))
          }

          notify_terminal_pressure(next)

          hook(s.config, :post_projection)
          hook(s.config, {:execution, 8, :post_projection})
          {:ok, job, next}

        {:error, reason} when reason in [:sequence_exhausted, :segment_id_exhausted] ->
          {:error, reason}

        _ ->
          exit(:writer_commit_unknown)
      end
    end
  end

  defp encoded_event(s, event, nil),
    do:
      Event.encode(
        event,
        s.config.value_limits,
        Keyword.fetch!(s.config.recovery, :max_decode_payload_bytes)
      )

  defp encoded_event(_s, event, payload), do: {:ok, {event.record_type, 1, payload}}

  defp ensure_generation_live!(%{fence: nil}), do: :ok

  defp ensure_generation_live!(s) do
    if LocalFence.live?(s.fence), do: :ok, else: exit(:execution_generation_revoked)
  end

  defp reservation_after(s, _previous, 3), do: s.settlement_reserve + 1

  defp reservation_after(s, %{state: :executing}, type) when type in [4, 5],
    do: s.settlement_reserve - 1

  defp reservation_after(s, _previous, _type), do: s.settlement_reserve

  defp telemetry_operation(1), do: :insert
  defp telemetry_operation(2), do: :make_available
  defp telemetry_operation(3), do: :start
  defp telemetry_operation(4), do: :finish
  defp telemetry_operation(5), do: :cancel
  defp telemetry_operation(6), do: :retry

  defp expected_position(s, payload_bytes) do
    rotate =
      s.segment.count > 0 and
        (s.segment.state == :sealed or
           s.segment.bytes + payload_bytes + 28 + 64 > s.config.rotation_target_bytes)

    %{
      sequence: s.next_sequence,
      segment_id: s.segment.id + if(rotate, do: 1, else: 0),
      offset: if(rotate, do: 44, else: s.segment.bytes)
    }
  end

  defp headroom(s, bytes, reserve) do
    cond do
      s.next_sequence + reserve > Segment.max_id() ->
        {:error, :sequence_exhausted}

      expected_position(s, bytes).segment_id + reserve > Segment.max_id() ->
        {:error, :segment_id_exhausted}

      over_limit?(
        s.history_bytes + history_delta(s, bytes) + outcome_reserve(reserve),
        s.config.max_history_bytes
      ) ->
        {:error, {:resource_limit, :max_history_bytes}}

      over_limit?(
        s.segment_count + expected_position(s, bytes).segment_id - s.segment.id + reserve,
        s.config.max_segments
      ) ->
        {:error, {:resource_limit, :max_segments}}

      true ->
        :ok
    end
  end

  # A fixed conservative operational reservation, not a persisted format limit:
  # every v1 finish/cancel fits 1,024 bytes including Record overhead, and each
  # reserved outcome may independently require a footer and successor header.
  defp outcome_reserve(count), do: count * (1_024 + 64 + 44)
  defp over_limit?(_, :infinity), do: false
  defp over_limit?(value, limit), do: value > limit

  defp history_delta(s, bytes) do
    rotates = expected_position(s, bytes).segment_id != s.segment.id
    bytes + 28 + if(rotates, do: 44 + if(s.segment.state == :sealed, do: 0, else: 64), else: 0)
  end

  defp blocked?(s, job),
    do:
      (not Map.has_key?(s.projection.registry, job.definition["worker_key"]) and
         not external_enabled?(s.config)) or
        not Map.has_key?(s.config.queues, job.definition["queue_key"])

  defp valid_worker_mapping?(config, key, worker) do
    (Map.get(config.workers, key) == worker and not is_nil(worker)) or
      (external_enabled?(config) and worker == Tay.Executor.RemoteWorker and
         not Map.has_key?(config.workers, key))
  end

  defp external_enabled?(config), do: is_binary(config.executor_socket)

  defp failure(s, kind, reason, raw),
    do: {{:error, Error.new(kind, reason, JobID.encode(raw), :insert)}, s}

  defp lookup_job(s, id),
    do: JobIndex.get(s.projection.jobs, id) || TerminalStore.get(s.terminal_store, id)

  defp account_active(s, previous, job) do
    hot_previous = previous && JobIndex.get(s.projection.jobs, previous.id)

    with {:ok, charged, budget} <- Transition.account(s.budget, hot_previous, job) do
      budget = if terminal?(charged), do: add_charge(budget, charged, -1), else: budget
      {:ok, charged, budget}
    end
  end

  defp publish_projection(s, previous, job) do
    hot_previous = previous && JobIndex.get(s.projection.jobs, previous.id)

    cond do
      terminal?(job) ->
        if hot_previous, do: :ok = Projection.delete(s.projection, hot_previous)
        :ok = TerminalStore.put(s.terminal_store, job)

      hot_previous ->
        :ok = Projection.replace(s.projection, hot_previous, job)

      true ->
        if previous, do: :ok = TerminalStore.delete(s.terminal_store, previous.id)
        :ok = Projection.replace(s.projection, nil, job)
    end
  end

  defp notify_terminal_pressure(s) do
    if s.terminal_budget.count > s.config.compaction.max_terminal_jobs,
      do: GenServer.cast(s.guardian, :terminal_pressure)

    :ok
  end

  defp compaction_terminal_limit(s) do
    limit = s.config.compaction.max_terminal_jobs

    if s.terminal_budget.count > limit,
      do: Tay.Engine.CompactionConfig.terminal_target(limit),
      else: limit
  end

  defp terminal_statistics(jobs) do
    Enum.reduce(jobs, empty_terminal_stats(), fn {_id, job}, stats ->
      if terminal?(job), do: update_terminal_stats(stats, job, 1), else: stats
    end)
  end

  defp replace_terminal_stats(stats, previous, job) do
    stats = if terminal?(previous), do: update_terminal_stats(stats, previous, -1), else: stats
    if terminal?(job), do: update_terminal_stats(stats, job, 1), else: stats
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
  defp zero_states, do: Map.new(@states, &{&1, 0})

  defp view(s, job),
    do: Job.view(job, s.config.workers, s.config.queues, s.store_id, s.generation, s.epoch_id)

  defp snapshot(s),
    do: %{
      state: s.mode,
      paused_queues: s.paused |> MapSet.to_list() |> Enum.sort(),
      jobs: s.active_budget.count + s.terminal_budget.count,
      active_jobs: s.active_budget.count,
      terminal_jobs: s.terminal_budget.count,
      blocked_jobs: s.blocked,
      state_bytes_charged: s.active_budget.bytes + s.terminal_budget.bytes,
      state_nodes_charged: s.active_budget.nodes + s.terminal_budget.nodes,
      active_state_bytes_charged: s.active_budget.bytes,
      active_state_nodes_charged: s.active_budget.nodes,
      terminal_state_bytes_charged: s.terminal_budget.bytes,
      terminal_state_nodes_charged: s.terminal_budget.nodes,
      max_jobs: s.config.max_jobs,
      max_state_bytes: s.config.max_state_bytes,
      max_state_nodes: s.config.max_state_nodes,
      startup_state_bytes_budget: 3 * s.config.max_state_bytes,
      running_executions: map_size(s.running),
      unsettled_executions: s.settlement_reserve,
      queue_slots_used: s.slots,
      execution_outcome_slots: Enum.sum(Map.values(s.config.queue_limits)),
      execution_control_slots: map_size(s.config.queue_limits) + 1,
      canonical_history_bytes: s.history_bytes,
      segment_count: s.segment_count,
      storage_segments: s.segment_catalog,
      storage_segments_truncated: s.segment_count > length(s.segment_catalog),
      compaction_terminal_retention: s.config.compaction.terminal_retention,
      max_terminal_jobs: s.config.compaction.max_terminal_jobs,
      retained_definition_bytes: s.definition_bytes,
      reserved_outcome_bytes: outcome_reserve(s.settlement_reserve),
      remaining_sequence_coordinates: max(Segment.max_id() - s.next_sequence + 1, 0),
      remaining_segment_coordinates: Segment.max_id() - s.segment.id,
      max_history_bytes: s.config.max_history_bytes,
      max_segments: s.config.max_segments,
      insertion_space: if(s.next_sequence > Segment.max_id(), do: :exhausted, else: :available)
    }

  defp partition_budgets(jobs) do
    Enum.reduce(jobs, {empty_budget(), empty_budget()}, fn {_, job}, {active, terminal} ->
      if terminal?(job) do
        {active, add_charge(terminal, job, 1)}
      else
        {add_charge(active, job, 1), terminal}
      end
    end)
  end

  defp replace_partition(budget, previous, job, kind) do
    budget =
      if previous && partition(previous) == kind,
        do: add_charge(budget, previous, -1),
        else: budget

    if partition(job) == kind, do: add_charge(budget, job, 1), else: budget
  end

  defp partition(job), do: if(terminal?(job), do: :terminal, else: :active)
  defp terminal?(nil), do: false
  defp terminal?(%{state: state}), do: state in [:completed, :cancelled, :discarded]
  defp empty_budget, do: %{count: 0, bytes: 0, nodes: 0}

  defp add_charge(budget, job, sign) do
    Map.merge(budget, %{
      count: budget.count + sign,
      bytes: budget.bytes + sign * job.charge.bytes,
      nodes: budget.nodes + sign * job.charge.nodes
    })
  end

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

  defp update_segment_catalog(s, receipt, payload_bytes) do
    active = %{
      id: receipt.segment_id,
      state: :active,
      bytes: receipt.offset + payload_bytes + 28,
      count: if(receipt.segment_id == s.segment.id, do: s.segment.count + 1, else: 1),
      first_sequence:
        if(receipt.segment_id == s.segment.id,
          do: List.last(s.segment_catalog).first_sequence,
          else: s.next_sequence
        ),
      last_sequence: s.next_sequence
    }

    catalog =
      if receipt.segment_id == s.segment.id do
        List.replace_at(s.segment_catalog, -1, active)
      else
        sealed =
          s.segment_catalog
          |> List.last()
          |> Map.merge(%{state: :sealed, bytes: s.segment.bytes + 64})

        s.segment_catalog
        |> List.replace_at(-1, sealed)
        |> Kernel.++([active])
      end

    Enum.take(catalog, -@segment_catalog_limit)
  end

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
