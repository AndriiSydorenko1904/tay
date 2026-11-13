defmodule Tay.Storage.V2.SegmentCleaner do
  @moduledoc "Selects sparse immutable segments using authenticated live-byte summaries."
  alias Tay.Storage.DiskIndex
  alias Tay.Storage.V2.CheckpointIndex, as: Index
  @max_input_bytes 64 * 1_048_576
  @max_segments 16

  def plan(native, source) do
    descriptor = source.incremental_roots

    with {:ok, roots} <- Index.roots(descriptor),
         {:ok, live} <- deduct_changes(native, source, roots, live_bytes(roots)),
         selected <- select(live),
         {:ok, source} <-
           Enum.reduce_while(selected, {:ok, source}, fn object, {:ok, acc} ->
             case collect_object(native, descriptor, source.epoch_id, roots, object, acc) do
               {:ok, next} -> {:cont, {:ok, next}}
               error -> {:halt, error}
             end
           end) do
      {:ok, Map.put(source, :cleaned_objects, selected)}
    end
  end

  def select(live) do
    live
    |> Enum.filter(fn
      {<<_::binary-size(16), 1, _::64, bytes::64>>, retained} ->
        retained > 0 and bytes > 108 and bytes - retained >= retained

      _ ->
        false
    end)
    |> Enum.sort_by(fn {<<_::binary-size(25), bytes::64>>, retained} ->
      retained - (bytes - retained)
    end)
    |> Enum.reduce({[], 0}, fn {object, _}, {selected, bytes} ->
      <<_::binary-size(25), size::64>> = object

      if length(selected) < @max_segments and bytes + size <= @max_input_bytes,
        do: {[object | selected], bytes + size},
        else: {selected, bytes}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp live_bytes(roots) do
    Enum.reduce([:root, :schedules, :results], %{}, fn role, acc ->
      Map.merge(acc, DiskIndex.live_bytes(roots[role]), fn _key, a, b -> a + b end)
    end)
  end

  defp deduct_changes(native, source, roots, live) do
    jobs = Enum.uniq(MapSet.to_list(source.dirty_jobs) ++ Map.keys(source.expired))

    changes = [
      root: jobs,
      schedules: Map.keys(source.schedules),
      results: Map.keys(source.results)
    ]

    read = Index.reader(native, source.epoch_id, :epoch)

    Enum.reduce_while(changes, {:ok, live}, fn {role, ids}, {:ok, acc} ->
      result =
        Enum.reduce_while(ids, {:ok, acc}, fn id, {:ok, values} ->
          case DiskIndex.fetch(read, roots[role], id) do
            {:ok,
             %{
               "epoch" => {:bytes, epoch},
               "segment" => segment,
               "segment_bytes" => bytes,
               "bytes" => record_bytes
             }} ->
              object = DiskIndex.object(epoch, 1, segment, bytes)
              {:cont, {:ok, Map.update(values, object, 0, &max(0, &1 - record_bytes))}}

            :not_found ->
              {:cont, {:ok, values}}

            error ->
              {:halt, error}
          end
        end)

      case result do
        {:ok, values} -> {:cont, {:ok, values}}
        error -> {:halt, error}
      end
    end)
  end

  defp collect_object(native, descriptor, epoch, roots, object, source) do
    read = Index.reader(native, epoch, :epoch)

    with {:ok, source} <-
           DiskIndex.reduce_object(read, roots.root, object, source, fn id, _pointer, acc ->
             if Map.has_key?(acc.expired, id) do
               {:ok, acc}
             else
               case Map.fetch(acc.jobs, id) do
                 {:ok, %{cold: true}} -> copy_job(native, descriptor, epoch, id, acc)
                 {:ok, _} -> {:ok, %{acc | dirty_jobs: MapSet.put(acc.dirty_jobs, id)}}
                 :error -> copy_job(native, descriptor, epoch, id, acc)
               end
             end
           end),
         {:ok, source} <-
           DiskIndex.reduce_object(read, roots.results, object, source, fn id, _pointer, acc ->
             if Map.has_key?(acc.expired, id) do
               {:ok, acc}
             else
               with {:ok, result} <-
                      if(Map.has_key?(acc.results, id),
                        do: {:ok, acc.results[id]},
                        else: Index.result(native, descriptor, epoch, id)
                      ),
                    {:ok, acc} <- ensure_result_job(read, roots.root, id, acc) do
                 {:ok, %{acc | results: Map.put(acc.results, id, result)}}
               end
             end
           end),
         do: {:ok, source}
  end

  defp copy_job(native, descriptor, epoch, id, source) do
    with {:ok, job} <- Index.fetch(native, descriptor, epoch, id),
         do:
           {:ok,
            %{
              source
              | jobs: Map.put(source.jobs, id, job),
                dirty_jobs: MapSet.put(source.dirty_jobs, id)
            }}
  end

  defp ensure_result_job(read, root, id, source) do
    if Map.has_key?(source.jobs, id) do
      {:ok, source}
    else
      with {:ok, pointer} <- DiskIndex.fetch(read, root, id),
           {:ok, job} <- Index.summary(pointer),
           do: {:ok, %{source | jobs: Map.put(source.jobs, id, job)}}
    end
  end
end
