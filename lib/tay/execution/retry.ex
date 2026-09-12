defmodule Tay.Execution.Retry do
  @moduledoc """
  Live Event v1 retry producer. Draws unbiased bounded integer jitter once;
  the resulting absolute due time is persisted, never redrawn during replay.
  Entropy exhaustion/failure is an infrastructure error, never a worker outcome.
  """
  alias Tay.Event.V1

  # An operational CPU bound, not a format constraint. Exhaustion refuses the
  # operation rather than switching to biased sampling or inventing a due time.
  @max_draws 128
  @sample_space 65_536

  def due_at(job, at, random_bytes \\ &:crypto.strong_rand_bytes/1)

  def due_at(%{attempt: attempt, definition: definition}, at, random_bytes)
      when is_map(definition) and is_function(random_bytes, 1) do
    if V1.time?(at) and V1.attempt?(attempt) and
         V1.attempt?(definition["max_attempts"]) and
         attempt <= definition["max_attempts"] and definition["retry_policy"] === V1.policy() do
      # Branch before exponentiation; no ordinal can request an enormous power.
      delay = if attempt >= 7, do: 60_000, else: 1000 * Integer.pow(2, attempt - 1)
      jitter_max = min(div(delay, 4), 60_000 - delay)

      with {:ok, jitter} <- jitter(jitter_max, random_bytes),
           do: {:ok, min(V1.max_time(), at + delay + jitter)}
    else
      {:error, :invalid_retry_context}
    end
  end

  def due_at(_, _, _), do: {:error, :invalid_retry_context}

  defp jitter(0, _), do: {:ok, 0}

  defp jitter(maximum, random_bytes) do
    count = maximum + 1
    # The accepted prefix contains exactly the same number of samples per
    # residue. Modulo is used only after rejecting the unequal remainder.
    cutoff = @sample_space - rem(@sample_space, count)
    sample(count, cutoff, random_bytes, @max_draws)
  end

  defp sample(_, _, _, 0), do: {:error, :random_source_failed}

  defp sample(count, cutoff, random_bytes, remaining) do
    case draw(random_bytes) do
      {:ok, sample} when sample < cutoff -> {:ok, rem(sample, count)}
      {:ok, _} -> sample(count, cutoff, random_bytes, remaining - 1)
      :error -> {:error, :random_source_failed}
    end
  end

  defp draw(random_bytes) do
    case random_bytes.(2) do
      <<sample::unsigned-big-16>> -> {:ok, sample}
      _ -> :error
    end
  catch
    _, _ -> :error
  end
end
