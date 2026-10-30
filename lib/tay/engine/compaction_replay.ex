defmodule Tay.Engine.CompactionReplay do
  @moduledoc "Shared pure lifecycle and auxiliary replay for startup and checkpoints."
  alias Tay.State.Transition
  alias Tay.State.Auxiliary
  alias Tay.Engine.CompactionEstimate

  def reduce(event, position, candidate) do
    if Tay.Event.V2.v2_type?(event.record_type) do
      Auxiliary.reduce(event, position, candidate)
    else
      reduce_job(event, position, candidate)
    end
  end

  defp reduce_job(event, position, candidate) do
    with {:ok, next} <- Transition.reduce(event, position, candidate) do
      id = event.data["job_id"]
      job = next.jobs[id]
      job = Map.put(job, :terminal_at, CompactionEstimate.terminal_time(job, event.data["at"]))
      {:ok, %{next | jobs: Map.put(next.jobs, id, job)}}
    end
  end
end
