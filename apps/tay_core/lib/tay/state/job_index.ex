defmodule Tay.State.JobIndex do
  @moduledoc false
  def new, do: :ets.new(__MODULE__, [:set, :private])
  def put(table, job), do: :ets.insert(table, {job.id, job})
  def delete(table, id), do: :ets.delete(table, id)

  def get(table, id) do
    case :ets.lookup(table, id) do
      [{^id, job}] -> job
      [] -> nil
    end
  end

  def count(table), do: :ets.info(table, :size)
  def fold(table, fun, acc), do: :ets.foldl(fn {_, job}, acc -> fun.(job, acc) end, acc, table)
end
