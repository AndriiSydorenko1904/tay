defmodule Tay.Engine.State do
  @moduledoc """
  One Engine generation's private runtime state. Field values, including ETS
  tables and settlement reserves, are mutated only by the Engine process.
  """
  @enforce_keys [:config, :guardian, :generation, :writer, :projection, :terminal_store]
  defstruct [
    :config,
    :guardian,
    :generation,
    :writer,
    :admission,
    :projection,
    :terminal_store,
    :schedules,
    :results,
    :terminal_stats,
    :budget,
    :active_budget,
    :terminal_budget,
    :volatile_terminal_budget,
    :compaction_estimate,
    :last_compaction_at,
    :events_since_checkpoint,
    :store_id,
    :epoch_id,
    :next_availability_order,
    :volatile_next_availability_order,
    :volatile_ids,
    :next_sequence,
    :segment,
    :segment_catalog,
    :runtime,
    :fence,
    :running,
    :executions,
    :slots,
    :relay_monitors,
    :controls,
    :executor_server,
    :control_wakes,
    :snapshot_pending,
    :snapshot_dirty,
    :settlement_reserve,
    :persistent_settlement_reserve,
    :mode,
    :paused,
    :drainers,
    :lifecycle_operation,
    :lifecycle_fenced,
    :online_compaction,
    :online_snapshot,
    :group_commit,
    :deferred_transitions,
    :memory_reclaim,
    :memory_reclaimed,
    :history_bytes,
    :segment_count,
    :blocked
  ]

  @type t :: %__MODULE__{}
end
