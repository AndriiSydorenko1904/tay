defmodule Tay.State.Projection do
  @moduledoc "Private disposable indexes. Only the owning Engine may read or update them."
  alias Tay.State.{JobIndex, QueueIndex, SchedulerIndex}
  @test Mix.env() == :test
  def new(registry, queues, hook \\ nil) do
    context = %{hook: if(@test, do: hook, else: nil)}
    jobs = JobIndex.new()
    hook(context, :job_index_created)
    queue = QueueIndex.new()
    hook(context, :queue_index_created)
    schedule = SchedulerIndex.new()
    hook(context, :scheduler_index_created)

    %{
      jobs: jobs,
      queue: queue,
      schedule: schedule,
      registry: registry,
      queues: queues,
      held: MapSet.new(),
      hook: if(@test, do: hook, else: nil)
    }
  end

  def load(projection, jobs) do
    Enum.each(jobs, fn {_, job} -> replace(projection, nil, job) end)
    projection
  end

  def replace(p, previous, job) do
    if previous && available?(p, previous), do: QueueIndex.delete(p.queue, previous)
    hook(p, :queue_removed)
    if previous && scheduled?(previous), do: SchedulerIndex.delete(p.schedule, previous)
    hook(p, :schedule_removed)
    JobIndex.put(p.jobs, job)
    hook(p, :job_written)
    if available?(p, job), do: QueueIndex.put(p.queue, job)
    hook(p, :queue_written)
    if scheduled?(job), do: SchedulerIndex.put(p.schedule, job)
    hook(p, :schedule_written)
    :ok
  end

  def available?(p, job),
    do:
      job.state == :available and Map.has_key?(p.registry, job.definition["worker_key"]) and
        Map.has_key?(p.queues, job.definition["queue_key"]) and not MapSet.member?(p.held, job.id)

  def scheduled?(job), do: job.state in [:scheduled, :retryable]

  def valid?(p) do
    {queue, schedule} =
      JobIndex.fold(
        p.jobs,
        fn job, {q, s} ->
          q = if available?(p, job), do: [{QueueIndex.key(job), job.id} | q], else: q
          s = if scheduled?(job), do: [{SchedulerIndex.key(job), job.revision} | s], else: s
          {q, s}
        end,
        {[], []}
      )

    Enum.sort(queue) == Enum.sort(:ets.tab2list(p.queue)) and
      Enum.sort(schedule) == Enum.sort(:ets.tab2list(p.schedule))
  end

  defp hook(p, point) do
    if @test and is_function(p.hook, 1), do: p.hook.({:projection, point})
    :ok
  end
end
