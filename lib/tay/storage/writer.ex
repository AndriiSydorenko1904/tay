defmodule Tay.Storage.Writer do
  @moduledoc """
  Internal physical storage session with a supervised native Port.

  The GenServer serializes storage operations and supervises its linked helper.
  The helper alone holds flock and writable FDs. A failed or uncertain mutation
  poisons this instance; no automatic restart/retry is permitted. An embedding
  supervisor may start this temporary child explicitly. Physical readiness is
  not Event validation, job insertion, or semantic recovery readiness.

  Strict group commits are private Engine-owned sessions: appends update the
  physical stream in order, one final sync/check closes the group, and the
  Engine alone withholds all external acknowledgements until that succeeds.
  """
  use GenServer, restart: :temporary
  alias Tay.Storage.{Native, Reader, Recovery}
  alias Tay.Storage.Recovery.Error

  alias Tay.Storage.Writer.{
    Compaction,
    Config,
    GroupCommit,
    OnlineCompaction,
    OnlineCompactionLifecycle,
    RecoveryLifecycle,
    SegmentOps,
    State
  }

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

  @doc false
  def initialize_if_missing(options) do
    case GenServer.start_link(__MODULE__, {:initialize_if_missing, options}) do
      {:ok, writer} ->
        case GenServer.call(writer, :finish_initialization, :infinity) do
          {:ok, _} -> :ok
          error -> error
        end

      :ignore ->
        :ok

      error ->
        error
    end
  end

  @doc "Replays an existing store, retaining its owner/Port/lock and private candidate."
  def start_recovered_link(storage_options, replay_spec) do
    with {:ok, storage} <- Config.new(storage_options),
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

  @doc false
  def begin_group_commit(writer, admission_ref),
    do: GenServer.call(writer, {:begin_group_commit, admission_ref}, :infinity)

  @doc false
  def finish_group_commit(writer, admission_ref),
    do: GenServer.call(writer, {:finish_group_commit, admission_ref}, :infinity)

  def seal(writer, admission_ref),
    do: GenServer.call(writer, {:admitted, admission_ref, :seal}, :infinity)

  def rotate(writer, admission_ref),
    do: GenServer.call(writer, {:admitted, admission_ref, :rotate}, :infinity)

  @doc "Runs the exclusive, drained-generation Store-v2 publisher in this native owner."
  def compact(
        writer,
        admission_ref,
        deadline \\ System.monotonic_time(:millisecond) + 900_000,
        retention \\ :infinity,
        captured_at \\ nil,
        cancel_flag \\ nil
      ),
      do:
        GenServer.call(
          writer,
          {:compact, admission_ref, deadline, retention, captured_at, cancel_flag},
          :infinity
        )

  @doc false
  def compact_online(
        writer,
        admission_ref,
        deadline,
        retention,
        captured_at,
        cancel_flag,
        notify,
        token,
        snapshot
      ),
      do:
        GenServer.call(
          writer,
          {:compact_online, admission_ref, deadline, retention, captured_at, cancel_flag, notify,
           token, snapshot},
          :infinity
        )

  @doc false
  def finish_online_freeze(writer, admission_ref, token),
    do: GenServer.call(writer, {:compact_online_freeze_ack, admission_ref, token}, :infinity)

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

    case RecoveryLifecycle.open(options, spec, budgets, deadline, caller) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  def init({:initialize_only, options}), do: init_physical(options, true)
  def init({:initialize_if_missing, options}), do: init_if_missing(options)
  def init(options), do: init_physical(options, false)

  defp init_if_missing(options) do
    Process.flag(:trap_exit, true)

    with {:ok, options} <- Config.new(options),
         {:ok, native} <- Native.open_if_missing(options.data_dir, Map.to_list(options)) do
      if native.facts.created do
        init_opened(native, options, true)
      else
        case Native.shutdown(native) do
          :ok -> :ignore
          error -> {:stop, error}
        end
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_physical(options, initialize_only) do
    Process.flag(:trap_exit, true)

    with {:ok, options} <- Config.new(options),
         {:ok, native} <- Native.open(options.data_dir, Map.to_list(options)) do
      init_opened(native, options, initialize_only)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_opened(native, options, initialize_only) do
    state = State.physical(native, options, initialize_only)

    case State.prepare(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        Native.shutdown(native)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, State.public_status(state), state}

  # Online compaction is orchestrated outside the Writer process, but every
  # native operation still executes here, in the sole Port owner. Individual
  # requests therefore interleave with ordinary durable appends without ever
  # sharing the Port concurrently.
  def handle_call(
        {:tay_native_request, generation, delegate, operation, body},
        {pid, _},
        %{
          native: %{generation: generation} = native,
          online_compaction: %{
            ref: delegate,
            pid: pid,
            deadline: deadline,
            cancel_flag: cancel_flag
          }
        } = state
      ) do
    OnlineCompactionLifecycle.native_request(
      state,
      native,
      deadline,
      cancel_flag,
      operation,
      body
    )
  end

  def handle_call({:tay_native_request, _, _, _, _}, _from, state),
    do: {:reply, {:error, %{kind: :native_owner, reason: :invalid_delegate}}, state}

  def handle_call(
        {:compact_online, reference, deadline, retention, captured_at, cancel_flag, notify, token,
         snapshot},
        {caller, _},
        %{recovery: _recovery, epoch_id: epoch_id} = state
      )
      when is_binary(epoch_id) and is_pid(notify) do
    OnlineCompactionLifecycle.start(
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
    )
  end

  def handle_call({:compact_online, _, _, _, _, _, _, _, _, _}, _, state),
    do: {:reply, {:error, :compaction_not_admitted}, state}

  def handle_call(
        {:compact_online_catch_up, ref, :poll},
        {pid, _},
        %{online_compaction: %{ref: ref, pid: pid, freezing: false, frozen: false} = online} =
          state
      ) do
    OnlineCompactionLifecycle.poll(state, online)
  end

  def handle_call(
        {:compact_online_catch_up, ref, :freeze},
        {pid, _} = from,
        %{online_compaction: %{ref: ref, pid: pid, freezing: false, frozen: false} = online} =
          state
      ) do
    OnlineCompactionLifecycle.freeze(state, online, from)
  end

  def handle_call(
        {:compact_online_freeze_ack, reference, token},
        {caller, _},
        %{
          recovery: %{caller: caller, admission_ref: reference},
          online_compaction:
            %{
              token: token,
              freezing: true,
              frozen: false,
              freeze_from: freeze_from
            } = online
        } = state
      ) do
    OnlineCompactionLifecycle.finish_freeze(state, online, freeze_from)
  end

  def handle_call(
        {:admitted, reference, request},
        from,
        %{recovery: recovery, online_compaction: %{frozen: true} = online} = state
      ) do
    if recovery.status == :ready and reference == recovery.admission_ref do
      {:noreply, %{state | online_compaction: OnlineCompaction.queue(online, from, request)}}
    else
      {:reply, {:error, :mutation_not_admitted}, state}
    end
  end

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
    case RecoveryLifecycle.activation_error(recovery, reference) do
      nil -> perform_recovery_activation(state, caller)
      %{reason: :activation_window_expired} = error -> recovery_failure(state, error)
      error -> {:reply, {:error, error}, state}
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

  def handle_call({:begin_group_commit, reference}, {caller, _}, %{recovery: recovery} = state)
      when is_map(recovery) do
    GroupCommit.begin(state, caller, reference)
  end

  def handle_call({:finish_group_commit, reference}, {caller, _}, state) do
    GroupCommit.finish(state, caller, reference, fn ->
      step(state, :append_synced, fn -> Native.sync(state.native) end)
    end)
  end

  def handle_call(
        {:compact, reference, deadline, retention, captured_at, cancel_flag},
        {caller, _},
        %{recovery: recovery} = state
      )
      when is_map(recovery) do
    if recovery.status == :ready and caller == recovery.caller and
         reference == recovery.admission_ref and is_integer(deadline) and
         deadline > System.monotonic_time(:millisecond) and
         Tay.Storage.V2.Retention.validate(retention) == :ok do
      case Compaction.run(state, deadline, retention, captured_at, cancel_flag) do
        {:ok, next, stats} ->
          {:reply, {:ok, stats}, next}

        {:error, failed_state, reason} ->
          {:reply, {:error, {:uncertain, reason}}, poison(failed_state, reason)}
      end
    else
      {:reply, {:error, :compaction_not_admitted}, state}
    end
  end

  def handle_call({:compact, _, _, _, _, _, _}, _, state),
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
    case SegmentOps.encode_candidate(state, type, schema, payload) do
      {:ok, bytes} ->
        case SegmentOps.append_with_capacity(state, bytes, type, schema, payload) do
          {:ok, next, receipt} ->
            {:reply, {:ok, receipt}, journal_compaction(next, {type, schema, payload})}

          {:reject, reason} ->
            {:reply, {:error, reason}, state}

          {:error, reason} ->
            {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
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
        case SegmentOps.seal(state) do
          {:ok, next} -> {:reply, {:ok, next.segment}, next}
          {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
        end
    end
  end

  defp mutate(:rotate, _from, state) do
    case SegmentOps.rotate(state) do
      {:ok, next} -> {:reply, {:ok, next.segment}, next}
      {:reject, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
    end
  end

  defp journal_compaction(
         %{online_compaction: %{frozen: false} = online} = state,
         {_, _, _} = record
       ) do
    %{state | online_compaction: OnlineCompaction.journal(online, record)}
  end

  defp journal_compaction(state, _record), do: state

  @impl true
  def handle_info(
        {:recovery_expired, reference},
        %{recovery: %{session_ref: reference, status: :awaiting_activation} = recovery} = state
      ) do
    if RecoveryLifecycle.expired?(recovery) do
      {:stop, :normal,
       poison(state, Error.new(:resource_limit, :activation_window_expired, :revalidation))}
    else
      RecoveryLifecycle.schedule_expiry(recovery)
      {:noreply, state}
    end
  end

  def handle_info({:recovery_expired, _}, state), do: {:noreply, state}

  def handle_info(
        {:compact_online_result, ref, pid, {:ok, %{recovered: recovered} = stats}},
        %{online_compaction: %{ref: ref, pid: pid} = online} = state
      ) do
    OnlineCompactionLifecycle.complete(state, online, recovered, stats, &mutate/3)
  end

  def handle_info(
        {:compact_online_result, ref, pid, {:error, reason}},
        %{online_compaction: %{ref: ref, pid: pid} = online} = state
      ) do
    OnlineCompactionLifecycle.fail(state, online, reason, &mutate/3)
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{online_compaction: %{monitor: monitor, pid: pid} = online} = state
      ) do
    OnlineCompactionLifecycle.builder_down(state, online, reason)
  end

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
    if MapSet.member?(ports, port) or Native.closed_by_owner?(port),
      do: {:noreply, state},
      else: {:stop, :unexpected_port, state}
  end

  def handle_info({:EXIT, port, reason}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, {:port_exit, reason})}

  def handle_info({:EXIT, port, _}, %{retired_ports: ports} = state) when is_port(port) do
    if MapSet.member?(ports, port) or Native.closed_by_owner?(port),
      do: {:noreply, state},
      else: {:stop, :unexpected_port, state}
  end

  def handle_info({port, {:data, _}}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, :unsolicited_native_reply)}

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    State.notify_lifecycle(state, :closed)
    Native.shutdown(state.native)
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :private_storage_session)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :storage_session_failed)

  defp perform_recovery_activation(state, caller) do
    case RecoveryLifecycle.activate(state, caller) do
      {:ok, summary, candidate, next} ->
        {:reply, {:ok, summary, candidate}, next, {:continue, :release_transient_heap}}

      {:error, error, failed_state} ->
        recovery_failure(failed_state, error)
    end
  end

  @impl true
  def handle_continue(:release_transient_heap, state) do
    :erlang.garbage_collect()
    {:noreply, state}
  end

  defp recovery_failure(state, error), do: {:reply, {:error, error}, poison(state, error)}

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
    defp hook(%{options: %{on_transition: fun}, native: native}, tag) when is_function(fun, 2),
      do: fun.(tag, native)

    defp hook(_, _), do: :ok
  end

  defp poison(state, reason), do: State.poison(state, reason)
end
