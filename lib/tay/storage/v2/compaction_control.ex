defmodule Tay.Storage.V2.CompactionControl do
  @moduledoc false
  # Volatile cancellation, not authority. Once CURRENT is in flight the owner
  # must finish verification/reconciliation, not interrupt publication.
  @key {__MODULE__, :owner_control}
  def install(flag), do: Process.put(@key, {flag, :building})
  def clear, do: Process.delete(@key)

  def requested? do
    case Process.get(@key) do
      {flag, _} when not is_nil(flag) -> :atomics.get(flag, 1) == 1
      _ -> false
    end
  end

  def cancelled? do
    case Process.get(@key) do
      {_, :building} -> requested?()
      _ -> false
    end
  end

  def begin_current do
    if cancelled?() do
      {:error, :compaction_cancelled}
    else
      case Process.get(@key) do
        {flag, _} -> Process.put(@key, {flag, :publishing})
        _ -> :ok
      end

      :ok
    end
  end
end
