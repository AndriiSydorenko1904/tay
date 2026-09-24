defmodule Tay.State.Transition do
  @moduledoc """
  The sole pure Event v1 lifecycle model, shared by live commands and replay.
  Prepare performs all business validation; apply binds only a validated physical
  position. There is no time, randomness, registry, ETS or I/O in this module.
  Candidate limits are operational accounting budgets, not format validity/RSS.
  """
  import Kernel, except: [apply: 2]
  alias Tay.Event
  alias Tay.Event.{V1, Value}

  def prepare(previous, %Event{} = event, limits \\ Value.defaults()) do
    with {:ok, _} <- Event.encode(event, limits),
         true <- valid_previous?(previous, event) || {:error, :invalid_transition},
         {:ok, definition_bytes} <- definition_bytes(previous, event, limits) do
      {:ok, %{previous: previous, event: event, definition_bytes: definition_bytes}}
    end
  end

  def apply(%{event: event} = prepared, %{sequence: sequence}) do
    if V1.sequence?(sequence) and event.data["expected_revision"] < sequence do
      {:ok, prepared |> next(sequence) |> Map.put(:revision, sequence)}
    else
      {:error, :invalid_position}
    end
  end

  def apply(_, _), do: {:error, :invalid_position}

  def candidate(limits \\ %{}, value_limits \\ Value.defaults()) do
    limits = Map.merge(%{max_jobs: 100_000, max_bytes: 268_435_456, max_nodes: 2_000_000}, limits)
    %{jobs: %{}, count: 0, bytes: 0, nodes: 0, limits: limits, value_limits: value_limits}
  end

  def reduce(%Event{} = event, position, candidate) do
    previous = Map.get(candidate.jobs, event.data["job_id"])

    with {:ok, effect} <- prepare(previous, event, candidate.value_limits),
         {:ok, job} <- apply(effect, position),
         {:ok, candidate} <- put_candidate(candidate, previous, job),
         do: {:ok, candidate}
  end

  def put_candidate(candidate, previous, job) do
    with {:ok, job} <- charge(job, candidate.value_limits),
         old <- if(active?(previous), do: previous.charge, else: %{bytes: 0, nodes: 0}),
         added <- if(active?(job), do: job.charge, else: %{bytes: 0, nodes: 0}),
         count <-
           candidate.count - if(active?(previous), do: 1, else: 0) +
             if(active?(job), do: 1, else: 0),
         bytes <- candidate.bytes - old.bytes + added.bytes,
         nodes <- candidate.nodes - old.nodes + added.nodes,
         :ok <- within_limits(candidate.limits, count, bytes, nodes) do
      {:ok,
       %{
         candidate
         | jobs: Map.put(candidate.jobs, job.id, job),
           count: count,
           bytes: bytes,
           nodes: nodes
       }}
    end
  end

  @doc false
  def accounting(candidate), do: Map.delete(candidate, :jobs)

  @doc false
  def account(budget, previous, job) do
    with {:ok, job} <- charge(job, budget.value_limits) do
      old = if previous, do: previous.charge, else: %{bytes: 0, nodes: 0}
      bytes = budget.bytes - old.bytes + job.charge.bytes
      nodes = budget.nodes - old.nodes + job.charge.nodes
      count = budget.count + if(previous, do: 0, else: 1)

      with :ok <- within_limits(budget.limits, count, bytes, nodes),
           do: {:ok, job, %{budget | count: count, bytes: bytes, nodes: nodes}}
    end
  end

  defp charge(job, value_limits) do
    {:ok, stats} = Value.measure(job.definition, value_limits)
    # Reserve a fixed metadata allowance, including the largest diagnostic, so
    # later lifecycle transitions cannot exceed an accepted job's state charge.
    charge = %{
      bytes: 2 * byte_size(job.definition_bytes) + 64 * stats.nodes + 2048,
      nodes: stats.nodes + 64
    }

    {:ok, Map.put(job, :charge, charge)}
  end

  defp within_limits(limits, count, bytes, nodes) do
    cond do
      count > limits.max_jobs ->
        {:error, {:resource_limit, :retained_jobs}}

      bytes > limits.max_bytes ->
        {:error, {:resource_limit, :retained_bytes}}

      nodes > limits.max_nodes ->
        {:error, {:resource_limit, :retained_nodes}}

      true ->
        :ok
    end
  end

  defp active?(nil), do: false
  defp active?(%{state: state}), do: state not in [:completed, :cancelled, :discarded]

  defp definition_bytes(nil, %Event{record_type: 1, data: data}, limits),
    do: Value.encode(data["definition"], limits)

  defp definition_bytes(previous, _, _), do: {:ok, previous.definition_bytes}

  defp valid_previous?(nil, %Event{record_type: 1}), do: true
  defp valid_previous?(nil, _), do: false
  defp valid_previous?(_, %Event{record_type: 1}), do: false

  defp valid_previous?(p, %Event{record_type: type, data: d}) do
    p.id == d["job_id"] and p.revision == d["expected_revision"] and valid_transition?(type, p, d)
  end

  defp valid_transition?(2, p, d),
    do: p.state in [:scheduled, :retryable] and p.eligible_at == d["due_at"]

  defp valid_transition?(3, p, d),
    do:
      p.state == :available and p.next_attempt == d["attempt"] and
        d["attempt"] <= p.definition["max_attempts"] and p.cycle == d["cycle_token"] and
        d["at"] >= p.eligible_at

  defp valid_transition?(4, p, d) do
    p.state == :executing and p.execution == d["execution_token"] and finish_transition?(p, d)
  end

  defp valid_transition?(5, p, d),
    do:
      p.state in [:available, :scheduled, :retryable, :executing] and
        d["execution_token"] == if(p.state == :executing, do: p.execution, else: nil)

  defp valid_transition?(6, p, d), do: {p.state, d["mode"]} in [{:retryable, 0}, {:discarded, 1}]

  defp finish_transition?(p, d) do
    {disposition, ordinal} =
      cond do
        d["outcome"] == 0 -> {0, nil}
        d["outcome"] == 3 -> {1, p.attempt}
        p.attempt < p.definition["max_attempts"] -> {1, p.attempt + 1}
        true -> {2, nil}
      end

    d["disposition"] == disposition and d["next_attempt"] == ordinal and
      if(disposition == 1, do: valid_due?(d["at"], p.attempt, d["next_due_at"]), else: true)
  end

  defp valid_due?(at, attempt, due) do
    {low, high} = V1.retry_interval(at, attempt)
    due >= low and due <= high
  end

  defp next(%{previous: nil, event: %{data: d}, definition_bytes: bytes}, sequence) do
    available = d["eligible_at"] <= d["at"]

    %{
      id: d["job_id"],
      definition: d["definition"],
      definition_bytes: bytes,
      state: if(available, do: :available, else: :scheduled),
      attempt: 0,
      next_attempt: 1,
      cycle: sequence,
      execution: nil,
      eligible_at: d["eligible_at"],
      available_sequence: if(available, do: sequence, else: nil),
      inserted_at: d["at"],
      attempted_at: nil,
      completed_at: nil,
      diagnostic: nil
    }
  end

  defp next(%{previous: p, event: %{record_type: 2, data: d}}, sequence),
    do: %{p | state: :available, eligible_at: d["due_at"], available_sequence: sequence}

  defp next(%{previous: p, event: %{record_type: 3, data: d}}, sequence),
    do: %{
      p
      | state: :executing,
        attempt: d["attempt"],
        execution: sequence,
        attempted_at: d["at"],
        available_sequence: nil,
        eligible_at: nil
    }

  defp next(%{previous: p, event: %{record_type: 4, data: d}}, _) do
    state =
      case d["disposition"] do
        0 -> :completed
        1 -> :retryable
        2 -> :discarded
      end

    %{
      p
      | state: state,
        next_attempt: d["next_attempt"],
        eligible_at: d["next_due_at"],
        execution: nil,
        completed_at: if(state == :completed, do: d["at"], else: p.completed_at),
        diagnostic: d["diagnostic"] || p.diagnostic
    }
  end

  defp next(%{previous: p, event: %{record_type: 5}}, _),
    do: %{
      p
      | state: :cancelled,
        execution: nil,
        next_attempt: nil,
        eligible_at: nil,
        available_sequence: nil
    }

  defp next(%{previous: p, event: %{record_type: 6, data: d}}, sequence) do
    p =
      if d["mode"] == 1,
        do: %{
          p
          | attempt: 0,
            next_attempt: 1,
            cycle: sequence,
            attempted_at: nil,
            completed_at: nil
        },
        else: p

    %{p | state: :available, eligible_at: d["at"], available_sequence: sequence, execution: nil}
  end
end
