defmodule Tay.Storage.V2.Reclaimer do
  @moduledoc """
  Best-effort post-CURRENT reclamation. Only the predecessor named by the
  independently recovered current manifest (or its exact adoption intent) is
  passed to the native helper. Failure is deferred, never a pointer rollback.
  """

  alias Tay.Storage.Native
  alias Tay.Storage.V2.Authority

  def predecessor(native, %{manifest: manifest, current: current} = recovered) do
    case manifest.source_epoch_id do
      nil -> legacy(native, recovered, current)
      id -> reclaim(native, "e-" <> Base.encode16(id, case: :lower), current, nil)
    end
  end

  defp legacy(native, recovered, current) do
    case Enum.find(recovered.root_entries, &(&1.name == "ADOPTION")) do
      nil ->
        {:ok, %{reclamation: :complete, reclaimed_bytes: 0}}

      %{type: :regular, size: 28, links: 1} = entry ->
        with {:ok, bytes} <- read_intent(native, entry),
             {:ok, nonce} <- Authority.decode_adoption(bytes) do
          reclaim(
            native,
            "legacy-" <> Base.encode16(nonce, case: :lower),
            current,
            bytes
          )
        end

      _ ->
        {:error, :invalid_adoption_intent}
    end
  end

  defp read_intent(native, entry) do
    with {:ok, opened} <- Native.open_read(native, :root, "ADOPTION") do
      result =
        if opened.device == entry.device and opened.inode == entry.inode,
          do: Native.read(native, 0, 28),
          else: {:error, :adoption_identity}

      case Native.close_read(native) do
        :ok -> result
        error -> error
      end
    end
  end

  defp reclaim(native, target, current, intent) do
    case Native.v2_reclaim(native, target, current, intent) do
      {:ok, bytes} -> {:ok, %{reclamation: :complete, reclaimed_bytes: bytes}}
      {:error, reason} -> {:ok, %{reclamation: :deferred, reclaimed_bytes: 0, reason: reason}}
    end
  end
end
