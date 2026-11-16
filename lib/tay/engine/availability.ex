defmodule Tay.Engine.Availability do
  @moduledoc false
  alias Tay.Engine.Persistence
  alias Tay.State.{Availability, JobIndex}

  # A closed dependency admits at most one probe across every associated queue.
  # Existing execution fences remain authoritative, including after reconnect.
  def allowed?(_s, nil), do: false

  def allowed?(s, job) do
    key = Availability.key(job)

    if is_nil(key) or get_in(s.availability, [key, "status"]) != "unavailable" do
      true
    else
      running =
        Enum.any?(s.running, fn {_, entry} ->
          case JobIndex.get(s.projection.jobs, entry.id) do
            nil -> false
            active -> Availability.key(active) == key
          end
        end)

      first = :ets.next(s.projection.dependency, {key, -1, -1, <<>>})

      probe =
        case first do
          {^key, _, _, id} -> id == job.id
          _ -> true
        end

      Tay.Execution.Clock.wall(s.config.clock) >= s.availability[key]["retry_at"] and not running and
        probe
    end
  end

  # Waking is bounded and journalled. A crash halfway through a wake resumes
  # from the durable available gate; explicit schedules and other errors keep
  # their original deadlines. Never mutate the canonical fixture/store directly.
  def wake(s), do: wake(s, :ets.first(s.projection.dependency), 32)
  defp wake(s, :"$end_of_table", _), do: {s, false}
  defp wake(s, _, 0), do: {s, true}

  defp wake(s, {key, _, _, id} = cursor, left) do
    next_cursor = :ets.next(s.projection.dependency, cursor)
    job = JobIndex.get(s.projection.jobs, id)

    if get_in(s.availability, [key, "status"]) == "available" and job.state == :retryable do
      at = Tay.Execution.Clock.wall(s.config.clock)

      event = %Tay.Event{
        record_type: 6,
        data: %{
          "at" => at,
          "expected_revision" => job.revision,
          "job_id" => id,
          "mode" => 0,
          "new_due_at" => at
        }
      }

      case Persistence.commit(s, job, event) do
        {:ok, _, next} -> wake(next, next_cursor, left - 1)
        {:error, _} -> {s, false}
      end
    else
      wake(s, next_cursor, left)
    end
  end
end
