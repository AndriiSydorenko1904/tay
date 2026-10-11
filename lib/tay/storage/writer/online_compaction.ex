defmodule Tay.Storage.Writer.OnlineCompaction do
  @moduledoc false

  @catch_up_target_events 1_024
  @catch_up_target_bytes 1_048_576
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
    delta: [],
    delta_events: 0,
    delta_bytes: 0,
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
          delta: [physical_record()],
          delta_events: non_neg_integer(),
          delta_bytes: non_neg_integer(),
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
    if online.delta_events > @catch_up_target_events or
         online.delta_bytes > @catch_up_target_bytes do
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
  def journal(%__MODULE__{frozen: false} = online, {_, _, payload} = record) do
    %{
      online
      | delta: [record | online.delta],
        delta_events: online.delta_events + 1,
        delta_bytes: online.delta_bytes + byte_size(payload) + @record_overhead_bytes
    }
  end

  @spec queue(t(), GenServer.from(), term()) :: t()
  def queue(%__MODULE__{} = online, from, request) do
    %{online | pending: [{from, request} | online.pending]}
  end

  defp clear_delta(online),
    do: %{online | delta: [], delta_events: 0, delta_bytes: 0}
end
