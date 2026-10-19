defmodule Tay.Storage.V2.Mutation do
  @moduledoc "Converts validated Engine events into Store-v2 logical mutations."

  alias Tay.Event

  @kinds %{
    1 => :inserted,
    2 => :available,
    3 => :started,
    4 => :finished,
    5 => :cancelled,
    6 => :retried
  }
  @common ~w(at expected_revision job_id)

  def from_event(%Event{record_type: type, data: data}, previous, next_order) do
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
end
