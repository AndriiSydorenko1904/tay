defmodule Tay.Telemetry do
  @moduledoc """
  Bounded telemetry emitted after successful live engine transitions.

  Job transitions use `[:tay, :job, :transition]` with `%{count: 1}` and
  metadata keys `:engine`, `:operation`, `:state`, `:previous_state`, `:queue`,
  and `:job_id`. Group commits use `[:tay, :storage, :group_commit]` with native
  time-unit measurements `:batch_size`, `:wait_time`, and `:fsync_duration`.
  Queue controls use `[:tay, :queue, :control]` with `%{count: 1}`
  and `:engine`, `:operation`, and `:queue` metadata. Arguments, diagnostics,
  definitions, revisions, PIDs, and storage paths are never included.
  """

  @job_event [:tay, :job, :transition]
  @queue_event [:tay, :queue, :control]
  @group_commit_event [:tay, :storage, :group_commit]

  @doc false
  def transition(engine, operation, previous, job) do
    :telemetry.execute(
      @job_event,
      %{count: 1},
      %{
        engine: engine,
        operation: operation,
        state: job.state,
        previous_state: if(previous, do: previous.state, else: nil),
        queue: job.definition["queue_key"],
        job_id: Tay.JobID.encode(job.id)
      }
    )
  end

  @doc false
  def queue_control(engine, operation, queue) do
    :telemetry.execute(@queue_event, %{count: 1}, %{
      engine: engine,
      operation: operation,
      queue: queue
    })
  end

  @doc false
  def group_commit(engine, size, wait_time, fsync_duration) do
    :telemetry.execute(
      @group_commit_event,
      %{batch_size: size, wait_time: wait_time, fsync_duration: fsync_duration},
      %{engine: engine}
    )
  end
end
