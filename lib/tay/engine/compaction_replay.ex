defmodule Tay.Engine.CompactionReplay do
  @moduledoc "Derives volatile V1 terminal times during the existing locked startup replay."
  alias Tay.State.Transition
  alias Tay.State.Auxiliary
  alias Tay.Engine.CompactionEstimate

  def reduce(event, position, candidate) do
    if event.record_type in 7..10 do
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
