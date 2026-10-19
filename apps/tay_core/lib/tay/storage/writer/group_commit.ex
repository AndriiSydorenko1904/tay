defmodule Tay.Storage.Writer.GroupCommit do
  @moduledoc false

  alias Tay.Storage.Native
  alias Tay.Storage.Writer.State

  @enforce_keys [:owner, :reference]
  defstruct [:owner, :reference, count: 0]

  @type t :: %__MODULE__{
          owner: pid(),
          reference: reference(),
          count: non_neg_integer()
        }

  @spec new(pid(), reference()) :: t()
  def new(owner, reference), do: %__MODULE__{owner: owner, reference: reference}

  @spec increment(t()) :: t()
  def increment(%__MODULE__{} = group), do: %{group | count: group.count + 1}

  def begin(state, caller, reference) do
    recovery = state.recovery

    cond do
      recovery.status != :ready or reference != recovery.admission_ref or
          caller != recovery.caller ->
        {:reply, {:error, :mutation_not_admitted}, state}

      state.options.durability != :sync ->
        {:reply, {:error, :group_commit_requires_sync}, state}

      Map.get(state, :group_commit) != nil ->
        {:reply, {:error, :group_commit_active}, state}

      true ->
        {:reply, :ok, Map.put(state, :group_commit, new(caller, reference))}
    end
  end

  def finish(state, caller, reference, sync) do
    case Map.get(state, :group_commit) do
      %__MODULE__{owner: ^caller, reference: ^reference, count: count} ->
        started = System.monotonic_time()
        result = if count == 0, do: :ok, else: sync.()
        duration = System.monotonic_time() - started

        finish_sync(state, result, count, duration)

      _ ->
        {:reply, {:error, :group_commit_not_active}, state}
    end
  end

  defp finish_sync(state, :ok, count, duration) do
    case Native.check(state.native) do
      :ok ->
        {:reply, {:ok, %{size: count, fsync_duration: duration}},
         Map.delete(state, :group_commit)}

      {:error, reason} ->
        {:reply, {:error, {:uncertain, reason}}, State.poison(state, reason)}
    end
  end

  defp finish_sync(state, {:error, reason}, _count, _duration),
    do: {:reply, {:error, {:uncertain, reason}}, State.poison(state, reason)}
end
