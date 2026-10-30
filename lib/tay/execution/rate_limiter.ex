defmodule Tay.Execution.RateLimiter do
  @moduledoc """
  Engine-local fixed-window execution limits. Only successful start commits
  consume credit. Windows use monotonic time and reset with the Engine generation.
  """
  alias Tay.Event.V2
  @max_policies 1_024

  def normalize(options, queues) do
    with true <- Keyword.keyword?(options),
         true <- length(options) == length(Enum.uniq(Keyword.keys(options))),
         true <- Enum.all?(Keyword.keys(options), &(&1 in [:queues, :tasks])),
         queue_rules <- Keyword.get(options, :queues, %{}),
         task_rules <- Keyword.get(options, :tasks, %{}),
         true <- rules?(queue_rules) and rules?(task_rules),
         true <- Enum.all?(Map.keys(queue_rules), &Map.has_key?(queues, &1)) do
      {:ok, %{queues: queue_rules, tasks: task_rules}}
    else
      _ -> {:error, :invalid_rate_limits}
    end
  end

  def new(policies), do: %{policies: policies, windows: %{}}

  def allowed?(limiter, queue, task, now) do
    Enum.all?(rules(limiter, queue, task), fn {key, policy} ->
      {_start, count} = window(limiter, key, policy, now)
      count < policy.limit
    end)
  end

  def consume(limiter, queue, task, now) do
    Enum.reduce(rules(limiter, queue, task), limiter, fn {key, policy}, acc ->
      {start, count} = window(acc, key, policy, now)
      %{acc | windows: Map.put(acc.windows, key, {start, count + 1})}
    end)
  end

  defp rules(limiter, queue, task) do
    for {kind, key} <- [{:queues, queue}, {:tasks, task}],
        policy = limiter.policies[kind][key],
        policy != nil,
        do: {{kind, key}, policy}
  end

  defp window(limiter, key, policy, now) do
    case Map.get(limiter.windows, key) do
      {start, count} when now - start < policy.interval_ms -> {start, count}
      _ -> {now, 0}
    end
  end

  defp rules?(rules)
       when is_map(rules) and not is_struct(rules) and map_size(rules) <= @max_policies do
    Enum.all?(rules, fn {key, policy} -> V2.key?(key) and policy?(policy) end)
  end

  defp rules?(_), do: false

  defp policy?(%{limit: limit, interval_ms: interval} = policy),
    do:
      map_size(policy) == 2 and is_integer(limit) and limit in 1..65_536 and
        is_integer(interval) and interval in 1..86_400_000

  defp policy?(_), do: false
end
