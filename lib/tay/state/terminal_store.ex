defmodule Tay.State.TerminalStore do
  @moduledoc "Disk-backed disposable projection for terminal job history."

  @terminal [:completed, :cancelled, :discarded]
  @slots 0..3

  defstruct [:table, :file, :registry, :slot]

  def open(name, data_dir, jobs) when is_atom(name) and is_binary(data_dir) and is_map(jobs) do
    :ok = File.mkdir_p(Path.dirname(data_dir))

    Enum.reduce_while(@slots, {:error, :terminal_projection_unavailable}, fn slot, _error ->
      file = data_dir <> ".terminal.#{slot}.dets"

      case claim_and_open(name, slot, file) do
        {:ok, table} ->
          with :ok <- :dets.delete_all_objects(table),
               :ok <- :dets.insert(table, terminal_objects(jobs)),
               :ok <- :dets.sync(table) do
            {:halt, {:ok, %__MODULE__{table: table, file: file, registry: name, slot: slot}}}
          else
            error ->
              :dets.close(table)
              release(name, slot)
              {:halt, error}
          end

        false ->
          {:cont, {:error, :terminal_projection_slot_busy}}

        {:error, _} = error ->
          release(name, slot)
          {:cont, error}
      end
    end)
  end

  def close(%__MODULE__{table: table, file: file, registry: registry, slot: slot}) do
    result = :dets.close(table)
    _ = File.rm(file)
    release(registry, slot)
    result
  end

  def get(%__MODULE__{table: table}, id) do
    case :dets.lookup(table, id) do
      [{^id, job}] -> job
      [] -> nil
    end
  end

  def put(%__MODULE__{table: table}, job), do: :dets.insert(table, {job.id, job})
  def delete(%__MODULE__{table: table}, id), do: :dets.delete(table, id)
  def count(%__MODULE__{table: table}), do: :dets.info(table, :size)

  def fold(%__MODULE__{table: table}, fun, accumulator),
    do: :dets.foldl(fn {_id, job}, acc -> fun.(job, acc) end, accumulator, table)

  defp open_file(file),
    do: :dets.open_file(make_ref(), file: String.to_charlist(file), type: :set, repair: :force)

  defp claim_and_open(registry, slot, file) do
    if claim(registry, slot) do
      _ = File.rm(file)
      open_file(file)
    else
      false
    end
  end

  defp claim(registry, slot) do
    key = {:terminal_projection, slot}

    case :ets.lookup(registry, key) do
      [{^key, owner}] when is_pid(owner) ->
        if Process.alive?(owner), do: false, else: :ets.delete_object(registry, {key, owner})

      [] ->
        :ok
    end

    :ets.insert_new(registry, {key, self()})
  end

  defp release(registry, slot),
    do: :ets.delete_object(registry, {{:terminal_projection, slot}, self()})

  defp terminal_objects(jobs) do
    Enum.flat_map(jobs, fn
      {id, %{state: state} = job} when state in @terminal -> [{id, job}]
      _ -> []
    end)
  end
end
