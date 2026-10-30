defmodule Tay.State.Memory do
  @moduledoc """
  One cooperative byte budget per Engine generation. Retained data and admitted
  payloads share the counter; this is an operational budget, not a VM RSS cap.
  """

  def new(limit), do: %{counter: :atomics.new(1, signed: true), limit: limit}
  def used(memory), do: :atomics.get(memory.counter, 1)

  def reserve(memory, bytes) when bytes >= 0 do
    current = used(memory)

    cond do
      current + bytes > memory.limit -> {:error, {:resource_limit, :retained_bytes}}
      :atomics.compare_exchange(memory.counter, 1, current, current + bytes) == :ok -> :ok
      true -> reserve(memory, bytes)
    end
  end

  def release(memory, bytes) when bytes >= 0 do
    :atomics.sub(memory.counter, 1, bytes)
    :ok
  end

  def settling(memory, fun) do
    key = {__MODULE__, memory.counter}

    if is_integer(Process.get(key)) do
      fun.()
    else
      Process.put(key, 0)

      try do
        fun.()
      after
        release(memory, Process.get(key, 0))
        Process.delete(key)
      end
    end
  end

  def transaction(memory, delta, fun),
    do: settling(memory, fn -> transact(memory, delta, fun) end)

  defp transact(memory, delta, fun) do
    key = {__MODULE__, memory.counter}

    with :ok <- take(memory, max(delta, 0)) do
      try do
        {actual, result} =
          case fun.() do
            {:memory_delta, actual, result} -> {actual, result}
            result -> {delta, result}
          end

        if is_tuple(result) and elem(result, 0) == :ok do
          extra = max(actual, 0) - max(delta, 0)

          if extra > 0 do
            # Capacity released by an adopted checkpoint is held as private
            # credit until the enclosing commit is fully published.
            :ok = take(memory, extra)
          else
            Process.put(key, Process.get(key) - extra)
          end

          if actual < 0, do: Process.put(key, Process.get(key) - actual)
        else
          Process.put(key, Process.get(key) + max(delta, 0))
        end

        result
      catch
        kind, reason ->
          Process.put(key, Process.get(key) + max(delta, 0))
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp take(memory, bytes) do
    key = {__MODULE__, memory.counter}
    credit = min(Process.get(key, 0), bytes)

    with :ok <- reserve(memory, bytes - credit) do
      Process.put(key, Process.get(key, 0) - credit)
      :ok
    end
  end

  # Include copied heap shape, off-heap binaries and fixed index/timer overhead.
  # Counting shared references conservatively avoids dependence on GC behaviour.
  def bytes(term),
    do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize) + binaries(term) + 128

  def schedule_bytes(nil), do: 0

  def schedule_bytes(schedule) do
    # Reserve the worst timestamp/revision shape up front. Cancelling or
    # advancing an accepted declaration must work even at full capacity.
    schedule =
      Map.merge(schedule, %{
        revision: 18_446_744_073_709_551_615,
        registered_at: 9_223_372_036_854_775_807,
        next_at: 9_223_372_036_854_775_807,
        last_at: 9_223_372_036_854_775_807,
        cancelled_at: 9_223_372_036_854_775_807,
        active_job_id: String.duplicate("f", 32)
      })

    # The Coordinator retains a runtime view too, including parsed cron fields.
    runtime =
      case Tay.Schedule.from_durable(schedule) do
        {:ok, value} -> value
        _ -> schedule
      end

    2 * bytes(schedule) + bytes(runtime) + 1_024
  end

  def result_bytes(nil), do: 0
  def result_bytes(result), do: bytes(result)

  def auxiliary_bytes(schedules, results) do
    Enum.reduce(schedules, 0, fn {_, value}, sum -> sum + schedule_bytes(value) end) +
      Enum.reduce(results, 0, fn {_, value}, sum -> sum + result_bytes(value) end)
  end

  # A JSON byte can expand to multiple BEAM words (small maps, arrays, numbers).
  # Reserve before accepting an external job, then exchange it for actual result
  # bytes on completion. Control/settlement never needs fresh data capacity.
  def result_reserve(max_json_bytes), do: max_json_bytes * 32 + 4_096

  def check(limits, bytes) do
    if bytes > limits.max_bytes do
      if Map.get(limits, :report_required, false),
        do: {:error, {:resource_limit, {:max_state_bytes, bytes, limits.max_bytes}}},
        else: {:error, {:resource_limit, :retained_bytes}}
    else
      :ok
    end
  end

  defp binaries(value) when is_binary(value), do: byte_size(value)

  defp binaries(value) when is_map(value),
    do: Enum.reduce(Map.to_list(value), 0, fn {k, v}, n -> n + binaries(k) + binaries(v) end)

  defp binaries(value) when is_list(value), do: Enum.reduce(value, 0, &(binaries(&1) + &2))
  defp binaries(value) when is_tuple(value), do: value |> Tuple.to_list() |> binaries()
  defp binaries(_), do: 0
end
