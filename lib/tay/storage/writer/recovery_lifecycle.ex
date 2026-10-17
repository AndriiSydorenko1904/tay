defmodule Tay.Storage.Writer.RecoveryLifecycle do
  @moduledoc false

  alias Tay.Storage.{Native, Recovery, Segment}
  alias Tay.Storage.Recovery.Error
  alias Tay.Storage.V2.Reclaimer
  alias Tay.Storage.V2.Reader, as: V2Reader
  alias Tay.Storage.V2.Reducer, as: V2Reducer
  alias Tay.Storage.Writer.SegmentOps

  @test Mix.env() == :test
  @max_timer_ms 4_294_967_295

  defmodule Session do
    @moduledoc false

    @enforce_keys [
      :status,
      :result,
      :candidate,
      :view,
      :provider,
      :session_ref,
      :caller,
      :monitor,
      :options,
      :expires_at
    ]
    defstruct [
      :status,
      :result,
      :candidate,
      :view,
      :provider,
      :session_ref,
      :admission_ref,
      :caller,
      :monitor,
      :options,
      :expires_at
    ]
  end

  def open(options, spec, budgets, deadline, caller) do
    native_options = [
      durability: options.durability,
      validated_filesystem: options.validated_filesystem,
      test_helper: options.test_helper,
      timeout: budgets.io_timeout_ms,
      max_directory_entries: budgets.max_directory_entries,
      deadline: deadline
    ]

    case Native.open_existing(options.data_dir, native_options) do
      {:ok, native} -> open_owned(native, options, spec, budgets, caller)
      {:error, reason} -> {:error, ownership_error(reason)}
    end
  end

  def schedule_expiry(recovery) do
    delay = max(recovery.expires_at - System.monotonic_time(:millisecond), 0)

    Process.send_after(
      self(),
      {:recovery_expired, recovery.session_ref},
      min(delay, @max_timer_ms)
    )
  end

  def expired?(recovery),
    do: System.monotonic_time(:millisecond) >= recovery.expires_at

  def activation_error(recovery, reference) do
    cond do
      recovery.status != :awaiting_activation ->
        Error.new(:ownership_unavailable, :already_activated, :activation)

      reference != recovery.session_ref ->
        Error.new(:ownership_unavailable, :stale_session, :activation)

      expired?(recovery) ->
        Error.new(:resource_limit, :activation_window_expired, :revalidation)

      true ->
        nil
    end
  end

  def activate(state, caller) do
    recovery = state.recovery

    native = %{
      state.native
      | deadline: System.monotonic_time(:millisecond) + recovery.options.activation_deadline_ms
    }

    state = %{state | native: native}

    with :ok <- hook(state, :recovery_revalidating),
         :ok <- revalidate(native, recovery),
         true <-
           (Process.alive?(caller) and Process.alive?(recovery.caller)) ||
             {:error, Error.new(:ownership_unavailable, :caller_lost, :revalidation)} do
      activate_validated(state, caller)
    else
      {:error, reason} -> {:error, Error.wrap(reason, :revalidation), state}
    end
  end

  defp open_owned(native, options, spec, budgets, caller) do
    state = initial_state(native, options, spec)

    with :ok <- hook(state, :recovery_acquired),
         {:ok, result, candidate, view, identity} <- prepare(native, spec),
         true <-
           Process.alive?(caller) ||
             {:error, Error.new(:ownership_unavailable, :caller_lost, :replay)},
         :ok <- hook(state, :recovery_replayed) do
      recovery = session(result, candidate, view, identity, budgets, caller)
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
        {:error, Error.wrap(reason, :replay)}
    end
  end

  defp initial_state(native, options, spec) do
    initial = spec.initial_acc

    %{
      native: native,
      options: options,
      segment: nil,
      store_id: nil,
      epoch_id: nil,
      v2_current: nil,
      candidate_limits: if(is_map(initial), do: Map.get(initial, :limits, %{}), else: %{}),
      value_limits:
        if(is_map(initial),
          do: Map.get(initial, :value_limits, Tay.Event.Value.defaults()),
          else: Tay.Event.Value.defaults()
        ),
      compacted: false,
      online_compaction: nil,
      inspection: nil,
      inspection_cache:
        :ets.new(:tay_storage_preview_cache, [
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ]),
      retired_ports: MapSet.new(),
      next_sequence: 1,
      poisoned: nil,
      recovery: nil
    }
  end

  defp session(result, candidate, view, identity, budgets, caller) do
    %Session{
      status: :awaiting_activation,
      result: result,
      candidate: candidate,
      view: view,
      provider: identity,
      session_ref: make_ref(),
      admission_ref: nil,
      caller: caller,
      monitor: Process.monitor(caller),
      options: budgets,
      expires_at: System.monotonic_time(:millisecond) + budgets.activation_window_ms
    }
  end

  defp ownership_error(reason) do
    error = Error.wrap(reason, :ownership)

    cond do
      match?(%{reason: "enoent"}, reason) ->
        %{error | kind: :ownership_unavailable, reason: :existing_root_or_lock_missing}

      match?(%{reason: "invalid_protocol"}, reason) ->
        %{error | kind: :ownership_unavailable, reason: :incompatible_native_helper}

      true ->
        error
    end
  end

  defp prepare(native, spec) do
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
            compaction_captured_at: view.manifest.captured_at,
            compaction_terminal_retention:
              if(view.manifest.source_frontier == 0 and view.manifest.source_segments == [],
                do: nil,
                else: view.manifest.terminal_retention
              ),
            checkpoint_tail_events: view.next_sequence - view.manifest.tail_first_sequence,
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
        {:error, Error.new(:discovery, :store_v2_required, :preflight)}
      end
    end
  end

  defp revalidate(native, %{provider: :store_v2, view: view}) do
    with {:ok, actual} <-
           V2Reader.recover(
             native,
             V2Reducer.candidate(view.candidate.limits, view.candidate.value_limits),
             selected: true
           ),
         true <- actual == view || {:error, :v2_frozen_view_changed},
         do: :ok
  end

  defp activate_validated(state, caller) do
    recovery = state.recovery

    with :ok <- Native.enable_mutations(state.native),
         :ok <- hook(state, :recovery_promoted),
         :ok <- maybe_reclaim(state),
         {:ok, next} <- open_recovered(state, recovery.view.store),
         :ok <- Recovery.check_deadline(state.native),
         true <-
           (Process.alive?(caller) and Process.alive?(recovery.caller)) || {:error, :caller_lost} do
      terminal = recovery.view.store.exhausted
      reference = if terminal, do: nil, else: make_ref()

      segment_catalog =
        recovery.result
        |> Map.get(:segments, [])
        |> Enum.map(&segment_catalog_entry/1)
        |> include_active_segment(next.segment)

      summary =
        recovery.result
        |> Map.drop([:segments])
        |> Map.merge(%{
          scope: :activated,
          state: if(terminal, do: :terminal, else: :ready),
          highest: next.segment,
          segment_catalog: segment_catalog,
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
          result: Map.drop(summary, [:admission_ref, :segment_catalog])
      }

      native = %{next.native | deadline: nil, timeout: next.options.timeout}
      if terminal, do: Native.shutdown(native)

      {:ok, summary, candidate, %{next | native: native, recovery: updated}}
    else
      {:error, reason} ->
        error = Error.wrap(reason, :activation)

        {:error,
         %{
           error
           | stage: :activation,
             kind: :uncertain_activation,
             mutation: :activation_uncertain
         }, state}
    end
  end

  defp open_recovered(state, %{exhausted: true}) do
    with :ok <- SegmentOps.sync_v2_authority(state),
         :ok <- Native.sync_dir(state.native, :root),
         :ok <- Native.sync_dir(state.native, :segments),
         :ok <- SegmentOps.sync_existing(state, :segments, canonical(state.segment.id)),
         :ok <- Native.check(state.native),
         do: {:ok, state}
  end

  defp open_recovered(state, store), do: SegmentOps.open_ready(state, store)

  defp maybe_reclaim(state) do
    {:ok, _} = Reclaimer.predecessor(state.native, state.recovery.view)
    Native.check(state.native)
  end

  defp segment_catalog_entry(segment),
    do: Map.take(segment, [:id, :state, :bytes, :count, :first_sequence, :last_sequence])

  defp include_active_segment([], segment), do: [segment_catalog_entry(segment)]

  defp include_active_segment(catalog, segment) do
    entry = segment_catalog_entry(segment)

    if List.last(catalog).id == entry.id,
      do: List.replace_at(catalog, -1, entry),
      else: catalog ++ [entry]
  end

  if @test do
    defp hook(%{options: %{on_transition: fun}, native: native}, tag) when is_function(fun, 2),
      do: fun.(tag, native)

    defp hook(_, _), do: :ok
  else
    defp hook(_, _), do: :ok
  end

  defp canonical(id), do: elem(Segment.filename(id), 1)
end
