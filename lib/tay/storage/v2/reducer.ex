defmodule Tay.Storage.V2.Reducer do
  @moduledoc """
  Pure Store-v2 logical replay. Physical positions are deliberately absent from
  revision, cycle, execution and availability state.
  """

  import Kernel, except: [apply: 2]

  alias Tay.State.Transition
  alias Tay.Storage.V2.Codec

  @max 18_446_744_073_709_551_615

  def candidate(limits \\ %{}, value_limits \\ Tay.Event.Value.defaults()) do
    Transition.candidate(limits, value_limits)
    |> Map.merge(%{next_availability_order: 1, availability_orders: MapSet.new()})
  end

  @doc "Validates one live logical transition without copying the Engine's ETS projection."
  def apply_one(previous, mutation, next_order, limits, value_limits) do
    seed = candidate(limits, value_limits)
    id = mutation.job_id

    seed =
      if previous do
        active = previous.state not in [:completed, :cancelled, :discarded]

        %{
          seed
          | jobs: %{id => previous},
            count: if(active, do: 1, else: 0),
            bytes: if(active, do: previous.charge.bytes, else: 0),
            nodes: if(active, do: previous.charge.nodes, else: 0),
            availability_orders:
              if(previous.availability_order,
                do: MapSet.new([previous.availability_order]),
                else: MapSet.new()
              )
        }
      else
        seed
      end

    with {:ok, next} <- apply(%{seed | next_availability_order: next_order}, mutation),
         do: {:ok, next.jobs[id], next.next_availability_order}
  end

  def insert_snapshot(candidate, job) do
    with :ok <- Codec.snapshot?(job, candidate.value_limits),
         true <- not Map.has_key?(candidate.jobs, job.id) || {:error, :duplicate_snapshot},
         true <-
           (is_nil(job.availability_order) or
              not MapSet.member?(candidate.availability_orders, job.availability_order)) ||
             {:error, :duplicate_availability_order},
         {:ok, next} <- Transition.put_candidate(candidate, nil, job) do
      {:ok, update_order(next, nil, job.availability_order, :snapshot)}
    end
  end

  def apply(candidate, mutation) do
    with :ok <- Codec.mutation?(mutation, candidate.value_limits),
         previous <- Map.get(candidate.jobs, mutation.job_id),
         :ok <- revision_gate(previous, mutation),
         :ok <- availability_gate(candidate, mutation),
         event <- Codec.event(mutation),
         {:ok, prepared} <- Transition.prepare(to_v1(previous), event, candidate.value_limits),
         {:ok, applied} <- Transition.apply(prepared, %{sequence: mutation.new_revision}),
         job <- from_v1(applied, mutation),
         :ok <- Codec.snapshot?(job, candidate.value_limits),
         {:ok, next} <- Transition.put_candidate(candidate, previous, job) do
      {:ok,
       update_order(
         next,
         if(previous, do: previous.availability_order, else: nil),
         job.availability_order,
         :mutation
       )}
    end
  end

  def durable_jobs(candidate) do
    Map.new(candidate.jobs, fn {id, job} -> {id, Map.drop(job, [:charge])} end)
  end

  defp revision_gate(nil, %{kind: :inserted, expected_revision: 0, new_revision: 1}), do: :ok
  defp revision_gate(nil, %{kind: :inserted}), do: {:error, :invalid_insert_revision}
  defp revision_gate(nil, _), do: {:error, :missing_job}
  defp revision_gate(_, %{kind: :inserted}), do: {:error, :duplicate_insert}

  defp revision_gate(%{revision: @max}, _), do: {:error, :logical_revision_exhausted}

  defp revision_gate(%{revision: revision}, %{expected_revision: revision, new_revision: next})
       when next == revision + 1,
       do: :ok

  defp revision_gate(_, _), do: {:error, :revision_conflict}

  defp to_v1(nil), do: nil

  defp to_v1(job),
    do: job |> Map.put(:available_sequence, job.availability_order)

  defp from_v1(job, mutation) do
    available =
      if job.state == :available and mutation.kind in [:inserted, :available, :retried],
        do: mutation.body["availability_order"],
        else: nil

    terminal_at = if job.state in [:completed, :cancelled, :discarded], do: mutation.at, else: nil

    job
    |> Map.delete(:available_sequence)
    |> Map.put(:availability_order, available)
    |> Map.put(:terminal_at, terminal_at)
  end

  defp availability_gate(candidate, mutation) do
    case mutation.body["availability_order"] do
      nil -> :ok
      order when order == candidate.next_availability_order and order <= @max -> :ok
      _ -> {:error, :availability_order_conflict}
    end
  end

  defp update_order(candidate, old, new, mode) do
    orders =
      candidate.availability_orders
      |> maybe_delete(old)
      |> maybe_put(new)

    next =
      if mode == :snapshot,
        do: max(candidate.next_availability_order, if(new, do: new + 1, else: 1)),
        else: if(new, do: new + 1, else: candidate.next_availability_order)

    %{candidate | availability_orders: orders, next_availability_order: next}
  end

  defp maybe_delete(set, nil), do: set
  defp maybe_delete(set, value), do: MapSet.delete(set, value)
  defp maybe_put(set, nil), do: set
  defp maybe_put(set, value), do: MapSet.put(set, value)
end
