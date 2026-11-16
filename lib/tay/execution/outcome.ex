defmodule Tay.Execution.Outcome do
  @moduledoc """
  Constant-size classification and construction of the single atomic finish
  Event. Raw callback results, exit reasons and exception objects are discarded;
  this module never invokes Inspect, Exception callbacks or user serialization.
  The Engine applies the existing pure transition validator before every append.
  """
  alias Tay.Event
  alias Tay.Event.V2
  alias Tay.Execution.Retry

  @type normalized ::
          :unavailable | :success | {:failure, 1 | 2 | 3 | 4 | 6} | :timeout | :interrupted

  @spec returned(term()) :: :unavailable | :success | {:failure, 1 | 6}
  def returned({:unavailable, _reason}), do: :unavailable
  def returned(:ok), do: :success
  def returned({:ok, _}), do: :success
  def returned({:error, _}), do: {:failure, 1}
  def returned(_), do: {:failure, 6}

  @spec caught(:error | :throw | :exit) :: {:failure, 2 | 3 | 4}
  def caught(:error), do: {:failure, 2}
  def caught(:throw), do: {:failure, 3}
  def caught(:exit), do: {:failure, 4}

  def event(job, outcome, at, random_bytes \\ &:crypto.strong_rand_bytes/1)

  def event(
        %{
          state: :executing,
          id: id,
          revision: revision,
          execution: execution,
          attempt: attempt,
          definition: definition
        } = job,
        outcome,
        at,
        random_bytes
      )
      when is_map(definition) and is_function(random_bytes, 1) do
    with true <-
           V2.id?(id) and V2.sequence?(revision) and V2.sequence?(execution) and V2.time?(at) and
             V2.attempt?(attempt) and
             (V2.attempt?(definition["max_attempts"]) or definition["max_attempts"] == "infinity") and
             attempt <= V2.attempt_limit(definition) and
             definition["retry_policy"] === V2.policy(),
         {:ok, wire_outcome, diagnostic} <- classify(outcome),
         true <- outcome != :unavailable or is_binary(definition["availability_key"]),
         {disposition, next_attempt} = disposition(outcome, attempt, definition),
         {:ok, due_at} <- due_at(disposition, job, at, random_bytes) do
      {:ok,
       %Event{
         record_type: 4,
         data: %{
           "at" => at,
           "diagnostic" => diagnostic,
           "disposition" => disposition,
           "execution_token" => execution,
           "expected_revision" => revision,
           "job_id" => id,
           "next_attempt" => next_attempt,
           "next_due_at" => due_at,
           "outcome" => wire_outcome
         }
       }}
    else
      false -> {:error, :invalid_outcome_context}
      {:error, _} = error -> error
    end
  end

  def event(_, _, _, _), do: {:error, :invalid_outcome_context}

  defp classify(:unavailable), do: {:ok, 4, diagnostic(8)}
  defp classify(:success), do: {:ok, 0, nil}
  defp classify({:failure, code}) when code in [1, 2, 3, 4, 6], do: {:ok, 1, diagnostic(code)}
  defp classify(:timeout), do: {:ok, 2, diagnostic(5)}
  defp classify(:interrupted), do: {:ok, 3, diagnostic(7)}
  defp classify(_), do: {:error, :invalid_outcome}
  defp diagnostic(code), do: %{"code" => code, "version" => 1}

  defp disposition(:success, _, _), do: {0, nil}
  defp disposition(:interrupted, attempt, _), do: {1, attempt}

  defp disposition(outcome, attempt, definition) do
    if outcome == :unavailable or definition["max_attempts"] == "infinity" or
         attempt < V2.attempt_limit(definition),
       do: {1, V2.next_attempt(definition, attempt)},
       else: {2, nil}
  end

  defp due_at(1, job, at, random_bytes), do: Retry.due_at(job, at, random_bytes)
  defp due_at(_, _, _, _), do: {:ok, nil}
end
