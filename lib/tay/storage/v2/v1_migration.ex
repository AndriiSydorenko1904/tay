defmodule Tay.Storage.V2.V1Migration do
  @moduledoc """
  Pure V1-to-V2 semantic projection for a completely validated V1 record stream.
  It retains the V1 reducer alongside V2 as an exact per-step oracle. Physical
  sequence is checked but never reused as a V2 logical revision or FIFO value.
  """

  alias Tay.Event
  alias Tay.State.Transition
  alias Tay.Storage.V2.Reducer

  @kinds %{
    1 => :inserted,
    2 => :available,
    3 => :started,
    4 => :finished,
    5 => :cancelled,
    6 => :retried
  }
  @common ~w(at expected_revision job_id)
  @semantic_fields ~w(id definition definition_bytes state attempt next_attempt eligible_at inserted_at attempted_at completed_at diagnostic)a

  def candidate(limits \\ %{}, value_limits \\ Tay.Event.Value.defaults()) do
    %{
      v1: Transition.candidate(limits, value_limits),
      v2: Reducer.candidate(limits, value_limits),
      next_physical_sequence: 1
    }
  end

  def reduce(
        %{next_physical_sequence: expected} = candidate,
        %Event{} = event,
        %{sequence: expected} = position
      ) do
    with {:ok, v1} <- Transition.reduce(event, position, candidate.v1),
         {:ok, mutation} <-
           translate_event(
             event,
             candidate.v2.jobs[event.data["job_id"]],
             candidate.v2.next_availability_order
           ),
         {:ok, v2} <- Reducer.apply(candidate.v2, mutation),
         true <-
           semantic_match?(v1.jobs[event.data["job_id"]], v2.jobs[event.data["job_id"]]) ||
             {:error, :migration_semantic_mismatch} do
      {:ok, %{candidate | v1: v1, v2: v2, next_physical_sequence: expected + 1}}
    end
  end

  def reduce(_, _, _), do: {:error, :v1_physical_sequence}

  @doc "Converts a validated Event intent to a logical V2 mutation."
  def translate_event(%Event{record_type: type, data: data}, previous, next_order) do
    with {:ok, kind} <- Map.fetch(@kinds, type) do
      expected = if previous, do: previous.revision, else: 0

      body =
        data
        |> Map.drop(@common)
        |> translate_tokens(kind, previous)
        |> maybe_availability(kind, data, next_order)

      {:ok,
       %{
         job_id: data["job_id"],
         kind: kind,
         expected_revision: expected,
         new_revision: expected + 1,
         at: data["at"],
         body: body
       }}
    end
  end

  defp translate_tokens(body, :started, previous),
    do: Map.put(body, "cycle_token", previous.cycle)

  defp translate_tokens(body, kind, previous) when kind in [:finished, :cancelled],
    do: Map.put(body, "execution_token", if(previous, do: previous.execution))

  defp translate_tokens(body, _, _), do: body

  defp maybe_availability(body, :inserted, data, next) do
    order = if data["eligible_at"] <= data["at"], do: next
    Map.put(body, "availability_order", order)
  end

  defp maybe_availability(body, kind, _, next) when kind in [:available, :retried],
    do: Map.put(body, "availability_order", next)

  defp maybe_availability(body, _, _, _), do: body

  defp semantic_match?(v1, v2) when is_map(v1) and is_map(v2),
    do: Map.take(v1, @semantic_fields) == Map.take(v2, @semantic_fields)

  defp semantic_match?(_, _), do: false
end
