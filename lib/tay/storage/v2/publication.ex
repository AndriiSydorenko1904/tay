defmodule Tay.Storage.V2.Publication do
  @moduledoc """
  Internal context for one candidate publication. Large intermediate snapshot
  views are released at stage boundaries instead of surviving the authority switch.
  The context carries data only; the Publisher controls all side-effect ordering.
  """
  @enforce_keys [:native, :source, :started, :limits, :value_limits]
  defstruct [
    :native,
    :source,
    :started,
    :limits,
    :value_limits,
    :normalized,
    :ids,
    :retention_stats,
    :auxiliary,
    :auxiliary_events,
    :inventory,
    :admitted_candidate_bytes,
    :epoch_id,
    :base_bytes,
    :peak_memory,
    :manifest,
    :manifest_bytes,
    :tail,
    :tail_bytes,
    :candidate,
    :caught_up,
    :delta_bytes,
    :switch_started,
    :catch_up_stats,
    :renamed,
    :current_bytes,
    :stage,
    :identity,
    :previous
  ]

  @type t :: %__MODULE__{}
end
