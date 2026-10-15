defmodule Tay.Storage.Writer.State do
  @moduledoc false

  alias Tay.Storage.{Native, Reader, Segment}
  alias Tay.Storage.Writer.SegmentOps

  @test Mix.env() == :test

  def physical(native, options, initialize_only) do
    %{
      native: native,
      options: options,
      segment: nil,
      store_id: nil,
      epoch_id: nil,
      v2_current: nil,
      candidate_limits: %{},
      value_limits: Tay.Event.Value.defaults(),
      compacted: false,
      online_compaction: nil,
      inspection: nil,
      inspection_cache: inspection_cache(),
      retired_ports: MapSet.new(),
      next_sequence: 1,
      poisoned: nil,
      initialize_only: initialize_only
    }
  end

  defp inspection_cache do
    :ets.new(:tay_storage_preview_cache, [
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  def prepare(state) do
    with {:ok, store} <- Reader.inspect_store(state.native) do
      case store.state do
        :uninitialized ->
          SegmentOps.bootstrap(state, store)

        :genesis ->
          SegmentOps.complete_genesis(%{state | store_id: store.store_id})

        :ready ->
          if Map.get(state, :initialize_only, false),
            do: {:error, :already_initialized},
            else: SegmentOps.open_ready(state, store)
      end
    end
  end

  def public_status(%{recovery: recovery} = state) when is_map(recovery) do
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

  def public_status(state) do
    %{
      state: if(state.poisoned, do: :poisoned, else: :ready),
      reason: state.poisoned,
      segment: state.segment,
      next_sequence: state.next_sequence,
      durability: state.options.durability,
      epoch_id: state.epoch_id,
      os_pid: state.native.facts.os_pid
    }
  end

  def poison(%{poisoned: nil} = state, reason) do
    # Revoke the embedding generation before potentially slow native cleanup.
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

  def poison(state, _reason), do: state

  def notify_lifecycle(state, event) do
    if pid = state.options.lifecycle_observer,
      do: send(pid, {Tay.Storage.Writer, self(), event})

    :ok
  end

  if @test do
    defp hook(%{options: %{on_transition: fun}, native: native}, tag) when is_function(fun, 2),
      do: fun.(tag, native)

    defp hook(_, _), do: :ok
  else
    defp hook(_, _), do: :ok
  end
end
