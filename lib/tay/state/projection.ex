defmodule Tay.State.Projection do
  @moduledoc "Private disposable indexes. Only the owning Engine may read or update them."
  alias Tay.State.{InspectionIndex, JobIndex, QueueIndex, SchedulerIndex, TaskIndex}
  @test Mix.env() == :test
  def new(registry, queues, hook \\ nil) do
    context = %{hook: test_hook(hook)}
    jobs = JobIndex.new()
    hook(context, :job_index_created)
    queue = QueueIndex.new()
    hook(context, :queue_index_created)
    task = TaskIndex.new()
    hook(context, :task_index_created)
    schedule = SchedulerIndex.new()
    hook(context, :scheduler_index_created)
    inspection = InspectionIndex.new()
    hook(context, :inspection_index_created)

    %{
      jobs: jobs,
      queue: queue,
      task: task,
      schedule: schedule,
      inspection: inspection,
      registry: registry,
      queues: queues,
      held: MapSet.new(),
      hook: test_hook(hook)
    }
  end

  def load(projection, jobs) do
    Enum.each(jobs, fn {_, job} -> replace(projection, nil, job) end)
    projection
  end

  def replace(p, previous, job) do
    if previous && available?(p, previous), do: QueueIndex.delete(p.queue, previous)
    hook(p, :queue_removed)
    if previous && task_available?(p, previous), do: TaskIndex.delete(p.task, previous)
    hook(p, :task_removed)
    if previous && scheduled?(previous), do: SchedulerIndex.delete(p.schedule, previous)
    hook(p, :schedule_removed)
    JobIndex.put(p.jobs, job)
    :ok = InspectionIndex.replace(p.inspection, previous, job)
    hook(p, :job_written)
    if available?(p, job), do: QueueIndex.put(p.queue, job)
    hook(p, :queue_written)
    if task_available?(p, job), do: TaskIndex.put(p.task, job)
    hook(p, :task_written)
    if scheduled?(job), do: SchedulerIndex.put(p.schedule, job)
    hook(p, :schedule_written)
    :ok
  end

  def available?(p, job),
    do:
      job.state == :available and Map.has_key?(p.registry, job.definition["worker_key"]) and
        Map.has_key?(p.queues, job.definition["queue_key"]) and not MapSet.member?(p.held, job.id)

  # Unlike `available?/2`, this does not require a permanent BEAM worker
  # mapping.  It is the durable ready set from which live external capability
  # advertisements select work.  Socket/process identities never enter this
  # index or the persisted job.
  def task_available?(p, job),
    do:
      job.state == :available and Map.has_key?(p.queues, job.definition["queue_key"]) and
        not MapSet.member?(p.held, job.id)

  def scheduled?(job), do: job.state in [:scheduled, :retryable]

  # A task fence is independent of the durable job state and queue credit.
  # Only the owner changes it; a retry must not overlap its terminating task.
  def hold(p, job) do
    if available?(p, job), do: QueueIndex.delete(p.queue, job)
    if task_available?(p, job), do: TaskIndex.delete(p.task, job)
    %{p | held: MapSet.put(p.held, job.id)}
  end

  def release(p, job) do
    p = %{p | held: MapSet.delete(p.held, job.id)}
    if available?(p, job), do: QueueIndex.put(p.queue, job)
    if task_available?(p, job), do: TaskIndex.put(p.task, job)
    p
  end

  def valid?(p) do
    {queue, task, schedule, jobs} =
      JobIndex.fold(
        p.jobs,
        fn job, {q, t, s, jobs} ->
          q = if available?(p, job), do: [{QueueIndex.key(job), job.id} | q], else: q
          t = if task_available?(p, job), do: [{TaskIndex.key(job), job.id} | t], else: t
          s = if scheduled?(job), do: [{SchedulerIndex.key(job), job.revision} | s], else: s
          {q, t, s, [job | jobs]}
        end,
        {[], [], [], []}
      )

    {inspection_entries, inspection_counts} = InspectionIndex.expected(jobs)

    Enum.sort(queue) == Enum.sort(:ets.tab2list(p.queue)) and
      Enum.sort(task) == Enum.sort(:ets.tab2list(p.task)) and
      Enum.sort(schedule) == Enum.sort(:ets.tab2list(p.schedule)) and
      Enum.sort(inspection_entries) == Enum.sort(InspectionIndex.entries(p.inspection)) and
      inspection_counts == InspectionIndex.counts(p.inspection)
  end

  if @test do
    defp test_hook(hook), do: hook

    defp hook(p, point) do
      if is_function(p.hook, 1), do: p.hook.({:projection, point})
      :ok
    end
  else
    defp test_hook(_hook), do: nil
    defp hook(_p, _point), do: :ok
  end
end
