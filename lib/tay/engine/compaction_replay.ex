defmodule Tay.Engine.CompactionReplay do
  @moduledoc "Derives volatile V1 terminal times during the existing locked startup replay."
  alias Tay.State.Transition
  alias Tay.Engine.CompactionEstimate

  def reduce(event, position, candidate) do
    with {:ok, next} <- Transition.reduce(event, position, candidate) do
      id = event.data["job_id"]
      job = next.jobs[id]
      job = Map.put(job, :terminal_at, CompactionEstimate.terminal_time(job, event.data["at"]))
      {:ok, %{next | jobs: Map.put(next.jobs, id, job)}}
    end
  end
end
