defmodule Tay.Storage.Writer.Bootstrap do
  @moduledoc false
  alias Tay.Storage.Native
  alias Tay.Storage.V2.Reader, as: V2Reader
  alias Tay.Storage.Writer.SegmentOps

  def prepare(state) do
    with {:ok, root} <- Native.list(state.native, :root) do
      names = MapSet.new(root, & &1.name)
      ownership_only? = MapSet.subset?(names, MapSet.new([".tay-owner.lock"]))

      cond do
        Enum.any?(root, &(&1.name in ["CURRENT", "STORE-V2"])) ->
          prepare_v2(state)

        state.native.facts.created or (state.options.bootstrap and ownership_only?) ->
          {:initialize, %{state | store_id: new_store_id()}}

        ownership_only? ->
          {:error, :explicit_bootstrap_required}

        true ->
          {:error, :store_v2_required}
      end
    end
  end

  defp prepare_v2(state) do
    with {:ok, recovered} <- V2Reader.recover_physical(state.native) do
      state = %{
        state
        | store_id: recovered.store_id,
          epoch_id: recovered.epoch_id,
          v2_current: recovered.current,
          next_sequence: recovered.next_sequence
      }

      SegmentOps.open_ready(state, recovered.store)
    end
  end

  def prepare_initialization(state) do
    with {:ok, entries} <- Native.list(state.native, :root) do
      names = MapSet.new(entries, & &1.name)
      ownership_only? = MapSet.subset?(names, MapSet.new([".tay-owner.lock"]))

      cond do
        state.native.facts.created or (state.options.bootstrap and ownership_only?) ->
          {:ok, %{state | store_id: new_store_id()}}

        ownership_only? ->
          {:error, :explicit_bootstrap_required}

        true ->
          {:error, :already_initialized}
      end
    end
  end

  defp new_store_id do
    case :crypto.strong_rand_bytes(16) do
      <<0::128>> -> new_store_id()
      id -> id
    end
  end
end
