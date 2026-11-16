defmodule Tay.State.Availability do
  @moduledoc """
  Durable dependency gates derived atomically from job mutations. A new insertion
  opens the gate (a producer hint); a successful execution confirms availability.
  Only an explicit unavailable outcome closes it. Snapshots preserve gates even
  after the signalling job's terminal history has expired.
  """
  alias Tay.State.Memory

  def key(job), do: job.definition["availability_key"]
  def waiting?(job), do: job.diagnostic == %{"code" => 8, "version" => 1}
  def bytes(nil), do: 0
  def bytes(key) when is_binary(key), do: 1024 + byte_size(key) * 2

  def added_bytes(states, job) do
    key = key(job)
    if is_binary(key) and not Map.has_key?(states, key), do: bytes(key), else: 0
  end

  def total(states), do: Enum.reduce(states, 0, fn {key, _}, sum -> sum + bytes(key) end)
  def index_key(key), do: <<0, "availability:", key::binary>>

  def update(states, operation, job) do
    case {key(job), operation, job.state, waiting?(job)} do
      {nil, _, _, _} ->
        states

      {key, 1, _, _} ->
        Map.put(states, key, %{"status" => "available", "retry_at" => 0})

      {key, 4, :completed, _} ->
        Map.put(states, key, %{"status" => "available", "retry_at" => 0})

      {key, 4, :retryable, true} ->
        Map.put(states, key, %{"status" => "unavailable", "retry_at" => job.eligible_at})

      _ ->
        states
    end
  end

  def apply(candidate, operation, job) do
    states = update(candidate.availability, operation, job)
    delta = if map_size(states) > map_size(candidate.availability), do: bytes(key(job)), else: 0

    with :ok <- Memory.check(candidate.limits, candidate.bytes + delta) do
      {:ok,
       %{
         candidate
         | availability: states,
           bytes: candidate.bytes + delta,
           auxiliary_bytes: candidate.auxiliary_bytes + delta
       }}
    end
  end
end
