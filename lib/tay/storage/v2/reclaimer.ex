defmodule Tay.Storage.V2.Reclaimer do
  @moduledoc """
  Best-effort post-CURRENT reclamation. Only the predecessor named by the
  independently recovered current manifest is passed to the native helper.
  Failure is deferred, never a pointer rollback.
  """

  alias Tay.Storage.Native

  def predecessor(native, %{manifest: manifest, current: current}) do
    case manifest.source_epoch_id do
      nil -> {:ok, %{reclamation: :complete, reclaimed_bytes: 0}}
      id -> reclaim(native, "e-" <> Base.encode16(id, case: :lower), current)
    end
  end

  defp reclaim(native, target, current) do
    case Native.v2_reclaim(native, target, current) do
      {:ok, bytes} -> {:ok, %{reclamation: :complete, reclaimed_bytes: bytes}}
      {:error, reason} -> {:ok, %{reclamation: :deferred, reclaimed_bytes: 0, reason: reason}}
    end
  end
end
