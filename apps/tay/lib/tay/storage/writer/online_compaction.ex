defmodule Tay.Storage.Writer.OnlineCompaction do
  @moduledoc false

  alias Tay.Storage.V2.CompactionLimits

  @record_overhead_bytes 28

  @enforce_keys [
    :ref,
    :pid,
    :monitor,
    :deadline,
    :cancel_flag,
    :notify,
    :token,
    :source
  ]
  defstruct [
    :ref,
    :pid,
    :monitor,
    :deadline,
    :cancel_flag,
    :notify,
    :token,
    :source,
    :freeze_from,
    :abort_reason,
    delta: [],
    delta_events: 0,
    delta_bytes: 0,
    peak_delta_events: 0,
    peak_delta_bytes: 0,
    max_delta_events: CompactionLimits.max_delta_events(),
    max_delta_bytes: CompactionLimits.max_delta_bytes(),
    freezing: false,
    frozen: false,
    pending: []
  ]

  @type physical_record :: {term(), term(), binary()}
  @type t :: %__MODULE__{
          ref: reference(),
          pid: pid(),
          monitor: reference(),
          deadline: integer(),
          cancel_flag: reference(),
          notify: pid(),
          token: term(),
          source: map(),
          freeze_from: GenServer.from() | nil,
          abort_reason: term() | nil,
          delta: [physical_record()],
          delta_events: non_neg_integer(),
          delta_bytes: non_neg_integer(),
          peak_delta_events: non_neg_integer(),
          peak_delta_bytes: non_neg_integer(),
          max_delta_events: pos_integer(),
          max_delta_bytes: pos_integer(),
          freezing: boolean(),
          frozen: boolean(),
          pending: [{GenServer.from(), term()}]
        }

  @spec new(keyword()) :: t()
  def new(attributes), do: struct!(__MODULE__, attributes)

  @spec drain(t()) :: {[physical_record()], t()}
  def drain(%__MODULE__{} = online) do
    {Enum.reverse(online.delta), clear_delta(online)}
  end

  @spec freeze(t(), GenServer.from()) :: {:catch_up, [physical_record()], t()} | {:freeze, t()}
  def freeze(%__MODULE__{} = online, from) do
    if online.delta_events > CompactionLimits.catch_up_target_events() or
         online.delta_bytes > CompactionLimits.catch_up_target_bytes() do
      {records, next} = drain(online)
      {:catch_up, records, next}
    else
      {:freeze, %{online | freezing: true, freeze_from: from}}
    end
  end

  @spec finish_freeze(t()) :: {[physical_record()], t()}
  def finish_freeze(%__MODULE__{} = online) do
    records = Enum.reverse(online.delta)

    next = %{
      online
      | freezing: false,
        frozen: true,
        freeze_from: nil,
        delta: [],
        delta_events: 0,
        delta_bytes: 0
    }

    {records, next}
  end

  @spec journal(t(), physical_record()) :: t()
  def journal(%__MODULE__{frozen: false, abort_reason: nil} = online, {_, _, payload} = record) do
    next = %{
      online
      | delta: [record | online.delta],
        delta_events: online.delta_events + 1,
        delta_bytes: online.delta_bytes + byte_size(payload) + @record_overhead_bytes,
        peak_delta_events: max(online.peak_delta_events, online.delta_events + 1),
        peak_delta_bytes:
          max(
            online.peak_delta_bytes,
            online.delta_bytes + byte_size(payload) + @record_overhead_bytes
          )
    }

    if next.delta_events > next.max_delta_events or next.delta_bytes > next.max_delta_bytes do
      :atomics.put(next.cancel_flag, 1, 1)

      %{
        next
        | abort_reason: :checkpoint_delta_overloaded,
          delta: [],
          delta_events: 0,
          delta_bytes: 0
      }
    else
      next
    end
  end

  def journal(%__MODULE__{} = online, _record), do: online

  @spec queue(t(), GenServer.from(), term()) :: t()
  def queue(%__MODULE__{} = online, from, request) do
    %{online | pending: [{from, request} | online.pending]}
  end

  defp clear_delta(online),
    do: %{online | delta: [], delta_events: 0, delta_bytes: 0}
end
