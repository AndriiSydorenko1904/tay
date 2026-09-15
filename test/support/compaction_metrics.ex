defmodule Tay.Test.CompactionMetrics do
  @moduledoc false
  # Qualification-only aggregate Logger handler. No job data or unbounded
  # production state: the gated workload executes exactly 101 evaluations.
  def log(%{meta: %{tay_compaction: data}}, %{table: table}) do
    :ets.update_counter(table, {:event, data.event}, {2, 1}, {{:event, data.event}, 0})

    if data.event == :evaluation_performed do
      n = :ets.lookup_element(table, {:event, data.event}, 2)
      :ets.insert(table, {{:evaluation, n}, data.evaluation_us})
    end

    :ok
  end

  def log(_, _), do: :ok
end
