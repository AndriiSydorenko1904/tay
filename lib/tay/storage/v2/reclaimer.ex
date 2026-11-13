defmodule Tay.Storage.V2.Reclaimer do
  @moduledoc """
  Best-effort post-CURRENT reclamation. Shared-index checkpoints retain files
  reachable from their authenticated roots and sweep old epochs in bounded
  native batches. Legacy checkpoints reclaim only their named predecessor.
  Failure is deferred, never a pointer rollback.
  """

  alias Tay.Storage.Native

  def predecessor(native, %{
        manifest: %{recovery_index: %{format: format} = descriptor} = manifest,
        current: current
      })
      when format in [2, 3] do
    with {:ok, keep} <- keep_objects(descriptor) do
      if manifest.source_epoch_id do
        case prune(native, manifest.source_epoch_id, current, keep) do
          {:ok, result} ->
            {:ok,
             %{
               reclamation: if(result.complete, do: :complete, else: :deferred),
               reclaimed_bytes: result.reclaimed_bytes
             }}

          {:error, reason} ->
            {:ok, %{reclamation: :deferred, reclaimed_bytes: 0, reason: reason}}
        end
      else
        {:ok, %{reclamation: :complete, reclaimed_bytes: 0}}
      end
    end
  end

  def predecessor(native, %{manifest: manifest, current: current}) do
    case manifest.source_epoch_id do
      nil -> {:ok, %{reclamation: :complete, reclaimed_bytes: 0}}
      id -> reclaim(native, "e-" <> Base.encode16(id, case: :lower), current)
    end
  end

  def start_background(state, %{
        manifest: %{recovery_index: %{format: format} = descriptor},
        current: current,
        epoch_id: epoch
      })
      when format in [2, 3] do
    stop_background(state)
    owner = self()
    reference = make_ref()
    native = %{state.native | deadline: nil, owner: owner, delegate: reference}

    {pid, monitor} =
      spawn_monitor(fn ->
        with {:ok, keep} <- keep_objects(descriptor),
             {:ok, entries} <- Native.list(native, :epochs) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case epoch_id(entry) do
              {:ok, ^epoch} ->
                {:cont, :ok}

              {:ok, old} ->
                case sweep_epoch(native, old, current, keep) do
                  :ok -> {:cont, :ok}
                  error -> {:halt, error}
                end

              _ ->
                {:cont, :ok}
            end
          end)
        end
      end)

    Map.put(state, :garbage, %{pid: pid, monitor: monitor, ref: reference})
  end

  def start_background(state, _view), do: state

  def stop_background(state) do
    case Map.get(state, :garbage) do
      %{pid: pid, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)

      _ ->
        :ok
    end

    :ok
  end

  defp keep_objects(descriptor) do
    with {:ok, objects} <- Tay.Storage.V2.CheckpointIndex.objects(descriptor) do
      {:ok,
       Enum.reduce(objects, %{}, fn
         <<epoch::binary-size(16), 0, 0::64, 0::64>>, acc ->
           Map.update(acc, epoch, %{recovery: true, segments: []}, &%{&1 | recovery: true})

         <<epoch::binary-size(16), 1, id::64, _bytes::64>>, acc ->
           Map.update(
             acc,
             epoch,
             %{recovery: false, segments: [id]},
             &%{&1 | segments: [id | &1.segments]}
           )
       end)}
    end
  end

  defp prune(native, epoch, current, keep) do
    objects = Map.get(keep, epoch, %{recovery: false, segments: []})
    Native.v2_prune(native, epoch, current, objects.recovery, Enum.uniq(objects.segments))
  end

  defp sweep_epoch(native, epoch, current, keep) do
    case prune(native, epoch, current, keep) do
      {:ok, %{complete: true}} -> :ok
      {:ok, %{complete: false}} -> sweep_epoch(native, epoch, current, keep)
      error -> error
    end
  end

  defp epoch_id(%{name: <<"e-", hex::binary-size(32)>>, type: :directory}),
    do: Base.decode16(hex, case: :lower)

  defp epoch_id(_), do: :ignore

  defp reclaim(native, target, current) do
    case Native.v2_reclaim(native, target, current) do
      {:ok, bytes} -> {:ok, %{reclamation: :complete, reclaimed_bytes: bytes}}
      {:error, reason} -> {:ok, %{reclamation: :deferred, reclaimed_bytes: 0, reason: reason}}
    end
  end
end
