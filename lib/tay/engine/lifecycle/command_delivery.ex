defmodule Tay.Engine.Lifecycle.CommandDelivery do
  @moduledoc """
  Generation-local FIFO delivery window. Lifecycle remains the only sender and
  permit owner. A yielded command leaves the window, not the admission table;
  its durable completion may arrive later. Unknown/duplicate acknowledgements
  cannot free capacity belonging to another permit.
  """
  defstruct pending: :queue.new(), active: MapSet.new()
  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  def enqueue(%__MODULE__{} = state, command),
    do: %{state | pending: :queue.in(command, state.pending)}

  def take(%__MODULE__{} = state, limit) do
    if MapSet.size(state.active) < limit do
      case :queue.out(state.pending) do
        {{:value, {_generation, permit, _payload, _from} = command}, pending} ->
          {:ok, command, %{state | pending: pending, active: MapSet.put(state.active, permit)}}

        {:empty, _} ->
          :empty
      end
    else
      :empty
    end
  end

  def complete(%__MODULE__{} = state, permit),
    do: %{state | active: MapSet.delete(state.active, permit)}

  def flush_limit(%__MODULE__{} = state),
    do: MapSet.size(state.active) + :queue.len(state.pending)

  def active_count(%__MODULE__{} = state), do: MapSet.size(state.active)
  def pending_count(%__MODULE__{} = state), do: :queue.len(state.pending)
end
