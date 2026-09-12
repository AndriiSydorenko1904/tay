defmodule Tay.Execution.Outcome do
  @moduledoc """
  Constant-size classification and construction of the single atomic finish
  Event. Raw callback results, exit reasons and exception objects are discarded;
  this module never invokes Inspect, Exception callbacks or user serialization.
  The Engine applies the existing pure transition validator before every append.
  """
  alias Tay.Event
  alias Tay.Event.V1
  alias Tay.Execution.Retry

  @type normalized :: :success | {:failure, 1 | 2 | 3 | 4 | 6} | :timeout | :interrupted

  @spec returned(term()) :: :success | {:failure, 1 | 6}
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
           V1.id?(id) and V1.sequence?(revision) and V1.sequence?(execution) and V1.time?(at) and
             V1.attempt?(attempt) and V1.attempt?(definition["max_attempts"]) and
             attempt <= definition["max_attempts"] and definition["retry_policy"] === V1.policy(),
         {:ok, wire_outcome, diagnostic} <- classify(outcome),
         {disposition, next_attempt} = disposition(outcome, attempt, definition["max_attempts"]),
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

  defp classify(:success), do: {:ok, 0, nil}
  defp classify({:failure, code}) when code in [1, 2, 3, 4, 6], do: {:ok, 1, diagnostic(code)}
  defp classify(:timeout), do: {:ok, 2, diagnostic(5)}
  defp classify(:interrupted), do: {:ok, 3, diagnostic(7)}
  defp classify(_), do: {:error, :invalid_outcome}
  defp diagnostic(code), do: %{"code" => code, "version" => 1}

  defp disposition(:success, _, _), do: {0, nil}
  defp disposition(:interrupted, attempt, _), do: {1, attempt}
  defp disposition(_, attempt, maximum) when attempt < maximum, do: {1, attempt + 1}
  defp disposition(_, _, _), do: {2, nil}

  defp due_at(1, job, at, random_bytes), do: Retry.due_at(job, at, random_bytes)
  defp due_at(_, _, _, _), do: {:ok, nil}
end
