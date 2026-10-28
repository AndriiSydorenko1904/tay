defmodule Tay.Storage.Writer.State do
  @moduledoc false

  alias Tay.Storage.Segment

  def physical(native, options, initialize_only, inspection_cache) do
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
      inspection_cache: inspection_cache,
      retired_ports: MapSet.new(),
      next_sequence: 1,
      poisoned: nil,
      initialize_only: initialize_only
    }
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

  def poisoned(state, reason) do
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
end
