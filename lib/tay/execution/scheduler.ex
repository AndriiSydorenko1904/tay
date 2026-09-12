defmodule Tay.Execution.Scheduler do
  @moduledoc false
  # Same one-outstanding-intent protocol as queue demand. Only Engine accesses
  # the due index or produces job_available; this process owns a bounded timer.
  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :permanent}
  end

  def start_link(options),
    do: Tay.Execution.Queue.start_link(Map.put(options, :kind, :scheduler))
end
