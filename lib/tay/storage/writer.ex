defmodule Tay.Storage.Writer do
  @moduledoc """
  Internal physical storage session with a supervised native Port.

  The GenServer serializes storage operations and supervises its linked helper.
  The helper alone holds flock and writable FDs. A failed or uncertain mutation
  poisons this instance; no automatic restart/retry is permitted. An embedding
  supervisor may start this temporary child explicitly. Physical readiness is
  not Event validation, job insertion, or semantic recovery readiness.
  """
  use GenServer, restart: :temporary
  alias Tay.Storage.{CRC32C, Native, Reader, Record, Recovery, Segment}
  alias Tay.Storage.Recovery.Error
  alias Tay.Storage.V2.{Publisher, Reclaimer, Snapshot, V1Migration}
  alias Tay.Storage.V2.Reducer, as: V2Reducer
  alias Tay.Storage.V2.Reader, as: V2Reader
  @test Mix.env() == :test

  def start_link(options) do
    if Keyword.keyword?(options),
      do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name])),
      else: {:error, :invalid_writer_options}
  end

  @doc "Initialize only using the approved bootstrap/genesis protocol; never open existing history."
  def initialize(options) do
    case GenServer.start_link(__MODULE__, {:initialize_only, options}) do
      {:ok, writer} -> GenServer.call(writer, :finish_initialization, :infinity)
      error -> error
    end
  end

  @doc "Replays an existing store, retaining its owner/Port/lock and private candidate."
  def start_recovered_link(storage_options, replay_spec) do
    with {:ok, storage} <- options(storage_options),
         true <-
           not storage.bootstrap ||
             {:error, Error.new(:argument, :recovery_cannot_bootstrap, :validation)},
         true <-
           (is_map(replay_spec) and
              Enum.sort(Map.keys(replay_spec)) == [:codec, :initial_acc, :options, :reducer]) ||
             {:error, Error.new(:argument, :invalid_replay_spec, :validation)},
         {:ok, budgets} <- Recovery.options(replay_spec.options),
         {:ok, _} <- Recovery.provider(replay_spec.codec, replay_spec.reducer) do
      deadline = System.monotonic_time(:millisecond) + budgets.deadline_ms

      GenServer.start_link(
        __MODULE__,
        {:recovered, storage, replay_spec, budgets, deadline, self()},
        Keyword.take(storage_options, [:name]) ++
          [timeout: budgets.deadline_ms + budgets.io_timeout_ms + 1_000]
      )
    else
      {:error, reason} -> {:error, Error.wrap(reason, :validation)}
    end
  end

  @doc "Activates once, in the same live ownership session; returns state input only after success."
  def activate_recovered(writer, session_ref),
    do: GenServer.call(writer, {:activate_recovered, session_ref}, :infinity)

  def append(writer, admission_ref, type, schema, payload),
    do:
      GenServer.call(
        writer,
        {:admitted, admission_ref, {:append, type, schema, payload}},
        :infinity
      )

  def seal(writer, admission_ref),
    do: GenServer.call(writer, {:admitted, admission_ref, :seal}, :infinity)

  def rotate(writer, admission_ref),
    do: GenServer.call(writer, {:admitted, admission_ref, :rotate}, :infinity)

  @doc "Runs the exclusive, drained-generation Store-v2 publisher in this native owner."
  def compact(writer, admission_ref, deadline \\ System.monotonic_time(:millisecond) + 900_000),
    do: GenServer.call(writer, {:compact, admission_ref, deadline}, :infinity)

  def status(writer), do: GenServer.call(writer, :status, :infinity)
  @doc "Appends opaque physical bytes supplied by an upstream semantic validator."
  def append(writer, type, schema, payload),
    do: GenServer.call(writer, {:append, type, schema, payload}, :infinity)

  def reduce(writer, accumulator, reducer),
    do: GenServer.call(writer, {:reduce, accumulator, reducer}, :infinity)

  def seal(writer), do: GenServer.call(writer, :seal, :infinity)
  def rotate(writer), do: GenServer.call(writer, :rotate, :infinity)

  if @test do
    def inject_fault(writer, operation, occurrence, action, errno \\ 5, count \\ 0),
      do: GenServer.call(writer, {:fault, operation, occurrence, action, errno, count}, :infinity)
  end

  @impl true
  def init({:recovered, options, spec, budgets, deadline, caller}) do
    Process.flag(:trap_exit, true)

    native_options = [
      durability: options.durability,
      validated_filesystem: options.validated_filesystem,
      test_helper: options.test_helper,
      timeout: budgets.io_timeout_ms,
      max_directory_entries: budgets.max_directory_entries,
      deadline: deadline
    ]

    case Native.open_existing(options.data_dir, native_options) do
      {:ok, native} ->
        state = %{
          native: native,
          options: options,
          segment: nil,
          store_id: nil,
          epoch_id: nil,
          v2_current: nil,
          candidate_limits:
            if(is_map(spec.initial_acc), do: Map.get(spec.initial_acc, :limits, %{}), else: %{}),
          value_limits:
            if(is_map(spec.initial_acc),
              do: Map.get(spec.initial_acc, :value_limits, Tay.Event.Value.defaults()),
              else: Tay.Event.Value.defaults()
            ),
          compacted: false,
          retired_ports: MapSet.new(),
          next_sequence: 1,
          poisoned: nil,
          recovery: nil
        }

        with :ok <- hook(state, :recovery_acquired),
             :ok <- V2Reader.reconcile_adoption(native),
             {:ok, result, candidate, view, identity} <-
               prepare_recovered(native, spec),
             true <-
               Process.alive?(caller) ||
                 {:error, Error.new(:ownership_unavailable, :caller_lost, :replay)},
             :ok <- hook(state, :recovery_replayed) do
          reference = make_ref()

          recovery = %{
            status: :awaiting_activation,
            result: result,
            candidate: candidate,
            view: view,
            provider: identity,
            session_ref: reference,
            admission_ref: nil,
            caller: caller,
            monitor: Process.monitor(caller),
            options: budgets,
            expires_at: System.monotonic_time(:millisecond) + budgets.activation_window_ms
          }

          schedule_expiry(recovery)

          {:ok,
           %{
             state
             | segment: view.store.highest,
               store_id: view.store.store_id,
               epoch_id: Map.get(view, :epoch_id),
               v2_current: Map.get(view, :current),
               next_sequence: view.store.next_sequence,
               recovery: recovery
           }}
        else
          {:error, reason} ->
            Native.shutdown(native)
            {:stop, Error.wrap(reason, :replay)}
        end

      {:error, reason} ->
        error = Error.wrap(reason, :ownership)

        error =
          if match?(%{reason: "enoent"}, reason),
            do: %{error | kind: :ownership_unavailable, reason: :existing_root_or_lock_missing},
            else: error

        error =
          if match?(%{reason: "invalid_protocol"}, reason),
            do: %{error | kind: :ownership_unavailable, reason: :incompatible_native_helper},
            else: error

        {:stop, error}
    end
  end

  def init({:initialize_only, options}), do: init_physical(options, true)
  def init(options), do: init_physical(options, false)

  defp init_physical(options, initialize_only) do
    Process.flag(:trap_exit, true)

    with {:ok, options} <- options(options),
         {:ok, native} <- Native.open(options.data_dir, Map.to_list(options)) do
      state = %{
        native: native,
        options: options,
        segment: nil,
        store_id: nil,
        epoch_id: nil,
        v2_current: nil,
        candidate_limits: %{},
        value_limits: Tay.Event.Value.defaults(),
        compacted: false,
        retired_ports: MapSet.new(),
        next_sequence: 1,
        poisoned: nil,
        initialize_only: initialize_only
      }

      case prepare(state) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          Native.shutdown(native)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:finish_initialization, _, %{initialize_only: true} = state) do
    result =
      case Native.shutdown(state.native) do
        :ok ->
          {:ok,
           %{
             store_id: state.store_id,
             segment_id: state.segment.id,
             durability: state.options.durability
           }}

        _ ->
          {:error, :uncertain_initialization}
      end

    {:stop, :normal, result, state}
  end

  def handle_call(_, _, %{initialize_only: true} = state),
    do: {:reply, {:error, :initialize_only}, state}

  def handle_call(_request, _from, %{poisoned: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, {:poisoned, reason}}, state}

  def handle_call(_request, _from, %{compacted: true} = state),
    do: {:reply, {:error, :compaction_restart_required}, state}

  def handle_call({:activate_recovered, reference}, {caller, _}, %{recovery: recovery} = state)
      when is_map(recovery) do
    cond do
      recovery.status != :awaiting_activation ->
        {:reply, {:error, Error.new(:ownership_unavailable, :already_activated, :activation)},
         state}

      reference != recovery.session_ref ->
        {:reply, {:error, Error.new(:ownership_unavailable, :stale_session, :activation)}, state}

      System.monotonic_time(:millisecond) >= recovery.expires_at ->
        recovery_failure(
          state,
          Error.new(:resource_limit, :activation_window_expired, :revalidation)
        )

      true ->
        activate(state, caller)
    end
  end

  def handle_call({:activate_recovered, _}, _, state),
    do:
      {:reply, {:error, Error.new(:ownership_unavailable, :not_recovered_session, :activation)},
       state}

  def handle_call({:admitted, reference, request}, from, %{recovery: recovery} = state)
      when is_map(recovery) do
    if recovery.status == :ready and is_reference(reference) and
         reference == recovery.admission_ref,
       do: mutate(request, from, state),
       else: {:reply, {:error, :mutation_not_admitted}, state}
  end

  def handle_call({:compact, reference, deadline}, {caller, _}, %{recovery: recovery} = state)
      when is_map(recovery) do
    if recovery.status == :ready and caller == recovery.caller and
         reference == recovery.admission_ref and is_integer(deadline) and
         deadline > System.monotonic_time(:millisecond) do
      state = %{state | native: %{state.native | deadline: deadline}}

      case compact_source(state) do
        {:ok, next, stats} -> {:reply, {:ok, stats}, %{next | compacted: true}}
        {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
      end
    else
      {:reply, {:error, :compaction_not_admitted}, state}
    end
  end

  def handle_call({:compact, _, _}, _, state),
    do: {:reply, {:error, :compaction_not_admitted}, state}

  def handle_call({:admitted, _, _}, _, state),
    do: {:reply, {:error, :not_recovered_session}, state}

  def handle_call({:append, _, _, _}, _, %{recovery: recovery} = state) when is_map(recovery),
    do: {:reply, {:error, :admission_reference_required}, state}

  def handle_call(request, _, %{recovery: recovery} = state)
      when is_map(recovery) and request in [:seal, :rotate],
      do: {:reply, {:error, :admission_reference_required}, state}

  def handle_call({:reduce, _, _}, _, %{recovery: %{status: status}} = state)
      when status != :ready, do: {:reply, {:error, :not_activated}, state}

  def handle_call({:append, _, _, _} = request, from, state), do: mutate(request, from, state)

  def handle_call(request, from, state) when request in [:seal, :rotate],
    do: mutate(request, from, state)

  def handle_call({:reduce, accumulator, reducer}, _from, state) do
    case Reader.reduce(state.native, accumulator, reducer) do
      {:ok, _} = result -> {:reply, result, state}
      {:error, reason} = result -> {:reply, result, poison(state, reason)}
    end
  end

  if @test do
    def handle_call({:fault, operation, occurrence, action, errno, count}, _from, state) do
      result = Native.fault(state.native, operation, occurrence, action, errno, count)
      {:reply, result, state}
    end
  end

  defp mutate({:append, type, schema, payload}, _from, state) do
    case encode_candidate(state, type, schema, payload) do
      {:ok, bytes} ->
        case append_with_capacity(state, bytes, type, schema, payload) do
          {:ok, next, receipt} -> {:reply, {:ok, receipt}, next}
          {:reject, reason} -> {:reply, {:error, reason}, state}
          {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp mutate(:seal, _from, state) do
    cond do
      state.segment.state == :sealed ->
        {:reply, {:error, :already_sealed}, state}

      state.segment.count == 0 ->
        {:reply, {:error, :empty_segment}, state}

      true ->
        case seal_segment(state) do
          {:ok, next} -> {:reply, {:ok, next.segment}, next}
          {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
        end
    end
  end

  defp mutate(:rotate, _from, state) do
    case rotate_segment(state) do
      {:ok, next} -> {:reply, {:ok, next.segment}, next}
      {:reject, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
    end
  end

  @impl true
  def handle_info(
        {:recovery_expired, reference},
        %{recovery: %{session_ref: reference, status: :awaiting_activation} = recovery} = state
      ) do
    if System.monotonic_time(:millisecond) >= recovery.expires_at do
      {:stop, :normal,
       poison(state, Error.new(:resource_limit, :activation_window_expired, :revalidation))}
    else
      schedule_expiry(recovery)
      {:noreply, state}
    end
  end

  def handle_info({:recovery_expired, _}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, _, _},
        %{recovery: %{monitor: monitor, status: :awaiting_activation}} = state
      ),
      do:
        {:stop, :normal,
         poison(state, Error.new(:ownership_unavailable, :caller_lost, :revalidation))}

  def handle_info(
        {port, {:exit_status, _}},
        %{native: %{port: port}, recovery: %{status: :terminal}} = state
      ),
      do: {:noreply, state}

  def handle_info(
        {:EXIT, port, _},
        %{native: %{port: port}, recovery: %{status: :terminal}} = state
      ),
      do: {:noreply, state}

  def handle_info({port, {:exit_status, code}}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, {:helper_exit, code})}

  def handle_info({port, {:exit_status, _}}, %{retired_ports: ports} = state) do
    if MapSet.member?(ports, port), do: {:noreply, state}, else: {:stop, :unexpected_port, state}
  end

  def handle_info({:EXIT, port, reason}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, {:port_exit, reason})}

  def handle_info({:EXIT, port, _}, %{retired_ports: ports} = state) when is_port(port) do
    if MapSet.member?(ports, port), do: {:noreply, state}, else: {:stop, :unexpected_port, state}
  end

  def handle_info({port, {:data, _}}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, :unsolicited_native_reply)}

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    notify_lifecycle(state, :closed)
    Native.shutdown(state.native)
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_storage_session)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :storage_session_failed)

  defp schedule_expiry(recovery) do
    delay = max(recovery.expires_at - System.monotonic_time(:millisecond), 0)

    Process.send_after(
      self(),
      {:recovery_expired, recovery.session_ref},
      min(delay, 4_294_967_295)
    )
  end

  defp prepare_recovered(native, spec) do
    with {:ok, root} <- Native.list(native, :root) do
      if Enum.any?(root, &(&1.name in ["CURRENT", "STORE-V2"])) do
        initial = spec.initial_acc

        with {:ok, view} <-
               V2Reader.recover(
                 native,
                 V2Reducer.candidate(initial.limits, initial.value_limits)
               ) do
          store = view.store
          count = Enum.reduce(store.segments, 0, &(&1.count + &2))

          summary = %{
            scope: :candidate,
            store_id: store.store_id,
            epoch_id: view.epoch_id,
            segments: store.segments,
            highest: store.highest,
            exhausted: store.exhausted,
            record_count: count,
            segment_count: length(store.segments),
            total_segment_bytes: view.total_segment_bytes,
            physical_last_sequence: if(count == 0, do: nil, else: store.next_sequence - 1),
            next_sequence: if(store.exhausted, do: :exhausted, else: store.next_sequence),
            arithmetic_next_sequence: store.next_sequence,
            staging_count: view.staging_count,
            ignored_count: view.ignored_count
          }

          {:ok, summary, view.candidate, view, :store_v2}
        end
      else
        Recovery.prepare(native, spec.codec, spec.initial_acc, spec.reducer, spec.options)
      end
    end
  end

  defp revalidate_recovered(native, %{provider: :store_v2, view: view}) do
    with {:ok, actual} <-
           V2Reader.recover(
             native,
             V2Reducer.candidate(view.candidate.limits, view.candidate.value_limits),
             selected: true
           ),
         true <- actual == view || {:error, :v2_frozen_view_changed},
         do: :ok
  end

  defp revalidate_recovered(native, recovery),
    do: Recovery.revalidate(native, recovery.view, recovery.provider, recovery.options)

  defp compact_source(state) do
    with {:ok, state} <- seal_compaction_frontier(state),
         {:ok, jobs, current} <- replay_compaction_source(state) do
      source = %{
        store_id: state.store_id,
        epoch_id: state.epoch_id,
        current: current,
        jobs: jobs,
        frontier: state.next_sequence - 1,
        rotation_target_bytes: state.options.rotation_target_bytes,
        candidate_limits: state.candidate_limits,
        value_limits: state.value_limits
      }

      result =
        case Publisher.publish(state.native, source) do
          {:error, {:unknown_publication_outcome, publication}} ->
            reconcile_publication(state, jobs, publication)

          other ->
            other
        end

      case result do
        {:ok, %{recovered: recovered} = stats} ->
          native = Map.get(stats, :native, state.native)

          reclaimed =
            if Map.has_key?(stats, :native) do
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

        error ->
          error
      end
    end
  end

  defp reconcile_publication(state, jobs, publication) do
    # The first Port may have completed the rename and lost only its reply.
    # Close it, reacquire for inspection, and accept only an independently
    # verified CURRENT naming this exact epoch and these exact durable jobs.
    Native.close(state.native)

    options = [
      durability: state.options.durability,
      validated_filesystem: state.options.validated_filesystem,
      test_helper: state.options.test_helper,
      timeout: state.options.timeout
    ]

    with {:ok, native} <- Native.open_existing(state.options.data_dir, options) do
      result =
        with {:ok, recovered} <-
               V2Reader.recover(
                 native,
                 V2Reducer.candidate(state.candidate_limits, state.value_limits)
               ),
             true <- recovered.epoch_id == publication.epoch_id || {:error, :old_current},
             true <- recovered.current == publication.current || {:error, :current_changed},
             true <-
               Snapshot.equivalent?(jobs, recovered.candidate.jobs) ||
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

      if match?({:ok, _}, result),
        do: result,
        else:
          (
            Native.shutdown(native)
            {:error, result}
          )
    end
  end

  defp seal_compaction_frontier(%{segment: %{state: :active, count: count}} = state)
       when count > 0 do
    with {:ok, rotated} <- rotate_segment(state),
         :ok <- Native.sync(rotated.native),
         :ok <- Native.close_write(rotated.native),
         :ok <- Native.sync_dir(rotated.native, :segments),
         do: {:ok, rotated}
  end

  defp seal_compaction_frontier(%{segment: %{state: :active}} = state) do
    with :ok <- Native.sync(state.native),
         :ok <- Native.close_write(state.native),
         :ok <- Native.sync_dir(state.native, :segments),
         do: {:ok, state}
  end

  defp seal_compaction_frontier(state), do: {:ok, state}

  defp replay_compaction_source(%{epoch_id: nil} = state) do
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

  defp replay_compaction_source(state) do
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

  defp activate(state, caller) do
    recovery = state.recovery

    native = %{
      state.native
      | deadline: System.monotonic_time(:millisecond) + recovery.options.activation_deadline_ms
    }

    state = %{state | native: native}

    with :ok <- hook(state, :recovery_revalidating),
         :ok <- revalidate_recovered(native, recovery),
         true <-
           (Process.alive?(caller) and Process.alive?(recovery.caller)) ||
             {:error, Error.new(:ownership_unavailable, :caller_lost, :revalidation)} do
      activate_validated(state, caller)
    else
      {:error, reason} -> recovery_failure(state, Error.wrap(reason, :revalidation))
    end
  end

  defp activate_validated(state, caller) do
    recovery = state.recovery

    with :ok <- Native.enable_mutations(state.native),
         :ok <- hook(state, :recovery_promoted),
         :ok <- maybe_reclaim_on_activation(state),
         {:ok, next} <- open_recovered(state, recovery.view.store),
         :ok <- Recovery.check_deadline(state.native),
         true <-
           (Process.alive?(caller) and Process.alive?(recovery.caller)) || {:error, :caller_lost} do
      terminal = recovery.view.store.exhausted
      reference = if terminal, do: nil, else: make_ref()

      summary =
        recovery.result
        |> Map.drop([:segments])
        |> Map.merge(%{
          scope: :activated,
          state: if(terminal, do: :terminal, else: :ready),
          highest: next.segment,
          admission_ref: reference
        })

      candidate = recovery.candidate
      Process.demonitor(recovery.monitor, [:flush])

      updated = %{
        recovery
        | status: summary.state,
          candidate: nil,
          view: nil,
          session_ref: nil,
          admission_ref: reference,
          result: Map.drop(summary, [:admission_ref])
      }

      native = %{next.native | deadline: nil, timeout: next.options.timeout}
      if terminal, do: Native.shutdown(native)
      {:reply, {:ok, summary, candidate}, %{next | native: native, recovery: updated}}
    else
      {:error, reason} ->
        error = Error.wrap(reason, :activation)

        recovery_failure(state, %{
          error
          | stage: :activation,
            kind: :uncertain_activation,
            mutation: :activation_uncertain
        })
    end
  end

  defp open_recovered(state, %{exhausted: true}) do
    with :ok <- sync_existing(state, :root, "STORE"),
         :ok <- sync_v2_authority(state),
         :ok <- Native.sync_dir(state.native, :root),
         :ok <- Native.sync_dir(state.native, :segments),
         :ok <- sync_existing(state, :segments, canonical(state.segment.id)),
         :ok <- Native.check(state.native),
         do: {:ok, state}
  end

  defp open_recovered(state, store), do: open_ready(state, store)

  defp recovery_failure(state, error), do: {:reply, {:error, error}, poison(state, error)}

  defp maybe_reclaim_on_activation(%{epoch_id: nil}), do: :ok

  defp maybe_reclaim_on_activation(state) do
    case Reclaimer.predecessor(state.native, state.recovery.view) do
      {:ok, _} -> Native.check(state.native)
      {:error, _} -> Native.check(state.native)
    end
  end

  defp inspect_for_writer(%{epoch_id: epoch_id} = state) when is_binary(epoch_id) do
    with {:ok, result} <-
           V2Reader.recover(
             state.native,
             V2Reducer.candidate(state.candidate_limits, state.value_limits),
             selected: true
           ),
         true <- result.epoch_id == epoch_id || {:error, :writer_epoch_changed} do
      {:ok, result.store}
    end
  end

  defp inspect_for_writer(%{recovery: %{status: :awaiting_activation, options: opts}} = state) do
    with {:ok, view} <- Reader.preflight(state.native, Map.to_list(opts)) do
      old = state.recovery.view

      normalize_root = fn entries ->
        Enum.map(entries, fn entry ->
          if entry.name == "segments" and entry.type == :directory,
            # APFS counts regular children in directory st_nlink. Publication
            # may change size/links, but never inode/mode or the exact inventory.
            do: Map.drop(entry, [:size, :links]),
            else: entry
        end)
      end

      old_entries =
        Enum.reject(view.segment_entries, &(&1.name == canonical(state.segment.id + 1)))

      if Enum.drop(view.store.segments, -1) == old.store.segments and
           view.marker == old.marker and view.marker_identity == old.marker_identity and
           old_entries == old.segment_entries and
           normalize_root.(view.root_entries) == normalize_root.(old.root_entries),
         do: {:ok, view.store},
         else: {:error, :unexpected_post_activation_history}
    end
  end

  defp inspect_for_writer(state), do: Reader.inspect_store(state.native)

  defp options(options) do
    allowed =
      [
        :name,
        :data_dir,
        :durability,
        :validated_filesystem,
        :rotation_target_bytes,
        :bootstrap,
        :lifecycle_observer,
        :timeout
      ] ++ test_option_keys()

    with true <- Keyword.keyword?(options) || {:error, :invalid_writer_options},
         true <-
           length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) ||
             {:error, :duplicate_writer_options},
         true <-
           Enum.all?(Keyword.keys(options), &(&1 in allowed)) || {:error, :unknown_writer_option},
         {:ok, config} <- Tay.Config.new(data_dir: Keyword.get(options, :data_dir)),
         true <- config.data_dir != nil || {:error, :data_dir_required} do
      opts =
        Enum.into(options, %{
          data_dir: config.data_dir,
          durability: :sync,
          validated_filesystem: false,
          rotation_target_bytes: 67_108_864,
          bootstrap: false,
          timeout: 10_000,
          test_helper: false,
          lifecycle_observer: nil,
          on_transition: nil
        })
        |> Map.put(:data_dir, config.data_dir)

      cond do
        opts.lifecycle_observer != nil and not is_pid(opts.lifecycle_observer) ->
          {:error, :invalid_lifecycle_observer}

        opts.durability not in [:write, :sync] ->
          {:error, :invalid_durability}

        not is_boolean(opts.validated_filesystem) ->
          {:error, :invalid_filesystem_validation}

        not is_boolean(opts.bootstrap) ->
          {:error, :invalid_bootstrap_intent}

        not is_integer(opts.timeout) or opts.timeout <= 0 ->
          {:error, :invalid_timeout}

        not is_integer(opts.rotation_target_bytes) or
          opts.rotation_target_bytes < Segment.min_rotation_bytes() or
            opts.rotation_target_bytes > Segment.max_bytes() ->
          {:error, :invalid_rotation_target}

        true ->
          {:ok, opts}
      end
    end
  end

  defp prepare(state) do
    with {:ok, store} <- Reader.inspect_store(state.native) do
      case store.state do
        :uninitialized ->
          bootstrap(state, store)

        :genesis ->
          complete_genesis(%{state | store_id: store.store_id})

        :ready ->
          if Map.get(state, :initialize_only, false),
            do: {:error, :already_initialized},
            else: open_ready(state, store)
      end
    end
  end

  defp encode_candidate(state, type, schema, payload) do
    if state.next_sequence > Segment.max_id() do
      {:error, :sequence_exhausted}
    else
      record = %Record{
        sequence: state.next_sequence,
        record_type: type,
        payload_schema_version: schema,
        payload: payload
      }

      Record.encode(record)
    end
  end

  defp append_with_capacity(state, bytes, type, schema, payload) do
    rotate =
      state.segment.state == :sealed or
        state.segment.bytes + byte_size(bytes) + 64 > state.options.rotation_target_bytes

    if rotate do
      with {:ok, next} <- rotate_segment(state),
           # Recompute the final frame only after the successor is published.
           {:ok, final} <- encode_candidate(next, type, schema, payload),
           do: append_bytes(next, final)
    else
      append_bytes(state, bytes)
    end
  end

  defp rotate_segment(%{segment: %{state: :active, count: 0}} = state), do: {:ok, state}

  defp rotate_segment(state) do
    cond do
      state.segment.id == Segment.max_id() ->
        {:reject, :segment_id_exhausted}

      state.next_sequence > Segment.max_id() ->
        {:reject, :sequence_exhausted}

      state.segment.state == :sealed ->
        create_successor(state)

      true ->
        with {:ok, sealed} <- seal_segment(state), do: create_successor(sealed)
    end
  end

  defp create_successor(state) do
    id = state.segment.id + 1
    source = stage_name(id)
    native = state.native

    with :ok <- sync_existing(state, :segments, canonical(state.segment.id)),
         {:ok, bytes} <-
           Segment.encode_header(%{
             id: id,
             first_sequence: state.next_sequence,
             store_id: state.store_id
           }),
         {:ok, identity} <-
           step(state, {:r3, :created}, fn -> Native.create_stage(native, :segments, source) end),
         {:ok, _} <- step(state, :r3, fn -> Native.write(native, 0, bytes) end),
         :ok <- step(state, {:r4, :synced}, fn -> Native.sync(native) end),
         :ok <- step(state, :r4, fn -> Native.close_write(native) end),
         :ok <-
           step(state, :r5, fn ->
             Native.publish(native, :segments, source, canonical(id), identity)
           end),
         :ok <- Native.sync_dir(native, :segments),
         {:ok, store} <- inspect_for_writer(state),
         true <-
           (store.highest.id == id and store.highest.state == :active and
              store.highest.count == 0 and store.next_sequence == state.next_sequence) ||
             {:error, :successor_mismatch},
         :ok <- step(state, :r6, fn -> Native.check(native) end),
         {:ok, _} <-
           step(state, :r7, fn ->
             Native.open_active(native, canonical(id), store.highest.identity)
           end),
         :ok <- Native.check(native) do
      {:ok, %{state | segment: store.highest}}
    end
  end

  defp append_bytes(state, bytes) do
    offset = state.segment.bytes

    with {:ok, %{identity: identity}} <-
           step(state, :append_written, fn -> Native.write(state.native, offset, bytes) end),
         :ok <- sync_append(state),
         :ok <- Native.check(state.native) do
      segment = %{
        state.segment
        | last_sequence: state.next_sequence,
          count: state.segment.count + 1,
          bytes: offset + byte_size(bytes),
          identity: identity,
          crc_state: CRC32C.update(state.segment.crc_state, bytes)
      }

      receipt = %{
        segment_id: segment.id,
        offset: offset,
        sequence: state.next_sequence,
        durability: state.options.durability
      }

      {:ok, %{state | segment: segment, next_sequence: state.next_sequence + 1}, receipt}
    end
  end

  defp sync_append(%{options: %{durability: :write}}), do: :ok
  defp sync_append(state), do: step(state, :append_synced, fn -> Native.sync(state.native) end)

  defp verify_current(state) do
    with {:ok, store} <- inspect_for_writer(state) do
      fields = [
        :id,
        :first_sequence,
        :store_id,
        :state,
        :last_sequence,
        :count,
        :bytes,
        :crc_state
      ]

      if Map.take(store.highest, fields) == Map.take(state.segment, fields) and
           store.highest.identity.device == state.segment.identity.device and
           store.highest.identity.inode == state.segment.identity.inode do
        {:ok, %{state | segment: store.highest}}
      else
        {:error, :writer_state_mismatch}
      end
    end
  end

  defp seal_segment(state) do
    with {:ok, state} <- step(state, :r0, fn -> verify_current(state) end) do
      footer = %{
        id: state.segment.id,
        first_sequence: state.segment.first_sequence,
        last_sequence: state.segment.last_sequence,
        count: state.segment.count,
        store_id: state.store_id,
        segment_crc: CRC32C.finalize(state.segment.crc_state)
      }

      with {:ok, bytes} <- Segment.encode_footer(footer),
           {:ok, %{identity: identity}} <-
             step(state, :r1, fn -> Native.write(state.native, state.segment.bytes, bytes) end),
           :ok <- step(state, {:r2, :synced}, fn -> Native.sync(state.native) end),
           :ok <- step(state, :r2, fn -> Native.close_write(state.native) end),
           :ok <- Native.check(state.native) do
        {:ok,
         %{
           state
           | segment: %{
               state.segment
               | state: :sealed,
                 footer: footer,
                 bytes: state.segment.bytes + 64,
                 identity: identity
             }
         }}
      end
    end
  end

  defp bootstrap(state, store) do
    if state.native.facts.created or state.options.bootstrap do
      state = %{state | store_id: new_store_id()}

      with :ok <- ensure_segments(state, store.segments_directory),
           {:ok, header} <-
             Segment.encode_header(%{id: 1, first_sequence: 1, store_id: state.store_id}),
           :ok <-
             publish_file(
               state,
               :segments,
               stage_name(1),
               canonical(1),
               header,
               :bootstrap_header
             ) do
        complete_genesis(state)
      end
    else
      {:error, :explicit_bootstrap_required}
    end
  end

  defp ensure_segments(_state, true), do: :ok

  defp ensure_segments(state, false) do
    with :ok <- step(state, {:bootstrap, :mkdir}, fn -> Native.mkdir_segments(state.native) end),
         :ok <-
           step(state, {:bootstrap, :sync_root}, fn -> Native.sync_dir(state.native, :root) end),
         do: :ok
  end

  defp complete_genesis(state) do
    with {:ok, marker} <- Segment.encode_store(state.store_id),
         :ok <- sync_existing(state, :segments, canonical(1)),
         :ok <- Native.sync_dir(state.native, :segments),
         :ok <-
           publish_file(
             state,
             :root,
             ".tay-store-" <> nonce() <> ".tmp",
             "STORE",
             marker,
             :bootstrap_store
           ),
         {:ok, store} <- Reader.inspect_store(state.native) do
      open_ready(state, store)
    end
  end

  defp open_ready(state, store) do
    state = %{
      state
      | segment: store.highest,
        store_id: store.store_id,
        next_sequence: store.next_sequence
    }

    with :ok <- sync_existing(state, :root, "STORE"),
         :ok <- sync_v2_authority(state),
         :ok <- Native.sync_dir(state.native, :root),
         :ok <- Native.sync_dir(state.native, :segments) do
      case store.highest.state do
        :active ->
          with :ok <- sync_existing(state, :segments, canonical(store.highest.id)),
               {:ok, _} <-
                 step(state, :open_active, fn ->
                   Native.open_active(
                     state.native,
                     canonical(store.highest.id),
                     store.highest.identity
                   )
                 end),
               :ok <- Native.check(state.native) do
            {:ok, state}
          end

        :sealed ->
          if store.exhausted, do: {:ok, state}, else: create_successor(state)
      end
    end
  end

  defp publish_file(state, scope, source, target, bytes, context) do
    with {:ok, identity} <-
           step(state, {context, :create}, fn ->
             Native.create_stage(state.native, scope, source)
           end),
         {:ok, _} <-
           step(state, {context, :write}, fn -> Native.write(state.native, 0, bytes) end),
         :ok <- step(state, {context, :sync}, fn -> Native.sync(state.native) end),
         :ok <- step(state, {context, :close}, fn -> Native.close_write(state.native) end),
         :ok <-
           step(state, {context, :publish}, fn ->
             Native.publish(state.native, scope, source, target, identity)
           end),
         :ok <- step(state, {context, :sync_dir}, fn -> Native.sync_dir(state.native, scope) end),
         :ok <- Native.check(state.native),
         do: :ok
  end

  defp sync_existing(state, scope, name) do
    with {:ok, _} <- Native.open_read(state.native, scope, name) do
      result = Native.sync_read(state.native)
      close = Native.close_read(state.native)
      if result == :ok, do: close, else: result
    end
  end

  defp sync_v2_authority(%{epoch_id: nil}), do: :ok

  defp sync_v2_authority(state) do
    with :ok <- sync_existing(state, :root, "STORE-V2"),
         :ok <- sync_existing(state, :root, "CURRENT"),
         :ok <- sync_existing(state, :epoch, "MANIFEST"),
         :ok <- Native.sync_dir(state.native, :epoch),
         :ok <- Native.sync_dir(state.native, :epochs),
         do: :ok
  end

  if @test do
    defp step(state, tag, operation) do
      case operation.() do
        {:error, _} = error ->
          error

        result ->
          case hook(state, tag) do
            :ok -> result
            error -> error
          end
      end
    end
  else
    defp step(_state, _tag, operation), do: operation.()
  end

  if @test do
    defp test_option_keys, do: [:test_helper, :on_transition]

    defp hook(%{options: %{on_transition: fun}, native: native}, tag) when is_function(fun, 2),
      do: fun.(tag, native)
  else
    defp test_option_keys, do: []
  end

  defp hook(_, _), do: :ok

  defp new_store_id do
    case :crypto.strong_rand_bytes(16) do
      <<0::128>> -> new_store_id()
      id -> id
    end
  end

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp canonical(id), do: elem(Segment.filename(id), 1)

  defp stage_name(id),
    do:
      ".tay-new-" <> String.replace_suffix(canonical(id), ".tay", "") <> "-" <> nonce() <> ".tmp"

  defp public_status(%{recovery: recovery} = state) when is_map(recovery) do
    %{
      state: if(state.poisoned, do: :poisoned, else: recovery.status),
      reason: state.poisoned,
      session_ref: recovery.session_ref,
      summary: Map.drop(recovery.result, [:segments]),
      next_sequence:
        if(recovery.status == :terminal or state.next_sequence > Segment.max_id(),
          do: :exhausted,
          else: state.next_sequence
        ),
      durability: state.options.durability,
      epoch_id: state.epoch_id,
      os_pid: state.native.facts.os_pid
    }
  end

  defp public_status(state),
    do: %{
      state: if(state.poisoned, do: :poisoned, else: :ready),
      reason: state.poisoned,
      segment: state.segment,
      next_sequence: state.next_sequence,
      durability: state.options.durability,
      epoch_id: state.epoch_id,
      os_pid: state.native.facts.os_pid
    }

  defp poison(%{poisoned: nil} = state, reason) do
    # Revoke the embedding generation before potentially slow native cleanup.
    # Never forward payloads, the Port or the recovered admission capability.
    notify_lifecycle(state, :poisoned)
    Native.shutdown(state.native)
    _ = hook(state, {:poisoned, reason})

    state =
      case Map.get(state, :recovery) do
        recovery when is_map(recovery) ->
          %{
            state
            | recovery: %{
                recovery
                | candidate: nil,
                  view: nil,
                  session_ref: nil,
                  admission_ref: nil
              }
          }

        _ ->
          state
      end

    %{state | poisoned: reason}
  end

  defp poison(state, _), do: state

  defp notify_lifecycle(state, event) do
    if pid = state.options.lifecycle_observer,
      do: send(pid, {__MODULE__, self(), event})

    :ok
  end
end
