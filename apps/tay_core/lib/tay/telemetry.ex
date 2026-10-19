defmodule Tay.Telemetry do
  @moduledoc """
  Bounded telemetry events and backend-neutral metric definitions.

  Job transitions use `[:tay, :job, :transition]` with `%{count: 1}` and
  metadata keys `:engine`, `:operation`, `:state`, `:previous_state`, `:queue`,
  and `:job_id`. Public requests emit the standard `[:tay, :command, :start]`,
  `:stop`, and `:exception` span events. Group commits use
  `[:tay, :storage, :group_commit]` with native
  time-unit measurements `:batch_size`, `:wait_time`, and `:fsync_duration`.
  Queue controls use `[:tay, :queue, :control]` with `%{count: 1}`
  and `:engine`, `:operation`, and `:queue` metadata. Arguments, diagnostics,
  definitions, revisions, PIDs, and storage paths are never included.

  `metrics/0` returns `Telemetry.Metrics` definitions suitable for Prometheus
  reporters and other compatible backends. The definitions deliberately omit
  job and schedule IDs, and queue labels are limited to configured queues.
  Add `poller_child_spec/1` to a host supervision tree to publish gauges.
  """

  import Telemetry.Metrics

  @job_event [:tay, :job, :transition]
  @queue_event [:tay, :queue, :control]
  @schedule_event [:tay, :schedule, :transition]
  @group_commit_event [:tay, :storage, :group_commit]
  @engine_availability_event [:tay, :engine, :availability]
  @engine_snapshot_event [:tay, :engine, :snapshot]
  @queue_snapshot_event [:tay, :queue, :snapshot]

  @events [
    [:tay, :command, :start],
    [:tay, :command, :stop],
    [:tay, :command, :exception],
    @job_event,
    @queue_event,
    @schedule_event,
    @group_commit_event,
    @engine_availability_event,
    @engine_snapshot_event,
    @queue_snapshot_event
  ]

  @doc "Returns every stable Telemetry event emitted by Tay."
  def events, do: @events

  @doc """
  Returns backend-neutral, low-cardinality metric definitions.

  Reporters may add their own global tags. Tay's definitions use only the
  configured engine and queue names plus finite operation/state/outcome values.
  Per-job and per-schedule identifiers are intentionally excluded.
  """
  def metrics do
    state_metrics =
      for state <- Tay.Inspection.states() do
        last_value("tay.engine.jobs.#{state}",
          event_name: @engine_snapshot_event,
          measurement: state,
          tags: [:engine],
          description: "Current Tay jobs in the #{state} state"
        )
      end

    [
      counter("tay.command.count",
        event_name: [:tay, :command, :stop],
        measurement: :duration,
        tags: [:engine, :operation, :outcome],
        description: "Completed Tay public commands"
      ),
      distribution("tay.command.duration.seconds",
        event_name: [:tay, :command, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:engine, :operation, :outcome],
        reporter_options: [
          buckets: [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30]
        ],
        description: "Tay public command latency"
      ),
      counter("tay.job.transition.count",
        event_name: @job_event,
        measurement: :count,
        tags: [:engine, :operation, :state],
        description: "Durable Tay job transitions"
      ),
      counter("tay.queue.control.count",
        event_name: @queue_event,
        measurement: :count,
        tags: [:engine, :operation, :queue],
        description: "Tay queue control operations"
      ),
      counter("tay.schedule.transition.count",
        event_name: @schedule_event,
        measurement: :count,
        tags: [:engine, :operation],
        description: "Durable Tay schedule transitions"
      ),
      distribution("tay.storage.group_commit.batch_size",
        event_name: @group_commit_event,
        measurement: :batch_size,
        tags: [:engine],
        reporter_options: [buckets: [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1_024]],
        description: "Records included in each Tay group commit"
      ),
      distribution("tay.storage.group_commit.wait_time.seconds",
        event_name: @group_commit_event,
        measurement: :wait_time,
        unit: {:native, :second},
        tags: [:engine],
        reporter_options: [
          buckets: [0.0001, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 1]
        ],
        description: "Time spent collecting a Tay group commit batch"
      ),
      distribution("tay.storage.group_commit.fsync_duration.seconds",
        event_name: @group_commit_event,
        measurement: :fsync_duration,
        unit: {:native, :second},
        tags: [:engine],
        reporter_options: [
          buckets: [0.0001, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 1, 5]
        ],
        description: "Tay group commit fsync latency"
      ),
      last_value("tay.engine.up",
        event_name: @engine_availability_event,
        measurement: :up,
        tags: [:engine],
        description: "Whether the Tay engine answered its bounded snapshot probe"
      ),
      last_value("tay.engine.jobs.total",
        event_name: @engine_snapshot_event,
        measurement: :jobs,
        tags: [:engine],
        description: "Current total retained Tay jobs"
      ),
      last_value("tay.engine.jobs.blocked",
        event_name: @engine_snapshot_event,
        measurement: :blocked_jobs,
        tags: [:engine],
        description: "Current Tay jobs blocked by missing runtime capabilities"
      ),
      last_value("tay.engine.executions.running",
        event_name: @engine_snapshot_event,
        measurement: :running_executions,
        tags: [:engine],
        description: "Current Tay executions"
      ),
      last_value("tay.engine.executions.unsettled",
        event_name: @engine_snapshot_event,
        measurement: :unsettled_executions,
        tags: [:engine],
        description: "Current Tay execution outcomes awaiting settlement"
      ),
      last_value("tay.engine.state_bytes",
        event_name: @engine_snapshot_event,
        measurement: :state_bytes_charged,
        tags: [:engine],
        unit: :byte,
        description: "Bytes charged to retained Tay state"
      ),
      last_value("tay.storage.history_bytes",
        event_name: @engine_snapshot_event,
        measurement: :canonical_history_bytes,
        tags: [:engine],
        unit: :byte,
        description: "Bytes in canonical Tay history"
      ),
      last_value("tay.storage.segments",
        event_name: @engine_snapshot_event,
        measurement: :segment_count,
        tags: [:engine],
        description: "Current Tay storage segment count"
      ),
      last_value("tay.engine.client_slots.used",
        event_name: @engine_snapshot_event,
        measurement: :client_slots_used,
        tags: [:engine],
        description: "Current Tay client admission slots in use"
      ),
      last_value("tay.engine.client_slots.capacity",
        event_name: @engine_snapshot_event,
        measurement: :client_slots,
        tags: [:engine],
        description: "Configured Tay client admission slot capacity"
      ),
      last_value("tay.schedule.active",
        event_name: @engine_snapshot_event,
        measurement: :active_schedules,
        tags: [:engine],
        description: "Current active durable Tay schedules"
      ),
      last_value("tay.schedule.cancelled",
        event_name: @engine_snapshot_event,
        measurement: :cancelled_schedules,
        tags: [:engine],
        description: "Current cancelled durable Tay schedules"
      ),
      last_value("tay.queue.jobs",
        event_name: @queue_snapshot_event,
        measurement: :jobs,
        tags: [:engine, :queue],
        description: "Current retained Tay jobs by queue"
      ),
      last_value("tay.queue.executing",
        event_name: @queue_snapshot_event,
        measurement: :executing,
        tags: [:engine, :queue],
        description: "Current Tay executions by queue"
      ),
      last_value("tay.queue.concurrency",
        event_name: @queue_snapshot_event,
        measurement: :concurrency,
        tags: [:engine, :queue],
        description: "Configured Tay concurrency by queue"
      ),
      last_value("tay.queue.paused",
        event_name: @queue_snapshot_event,
        measurement: :paused,
        tags: [:engine, :queue],
        description: "Whether a Tay queue is paused"
      )
      | state_metrics
    ]
  end

  @doc "Returns a child specification for periodic engine and queue gauges."
  def poller_child_spec(options \\ []), do: Tay.Telemetry.Poller.child_spec(options)

  @doc """
  Attaches Tay command spans to `opentelemetry_telemetry` when it is installed.

  The host application owns the OpenTelemetry SDK, processor, and exporter.
  Options are `:tracer_id` (default `:tay`) and `:handler_id`, which is also
  accepted by `detach_opentelemetry/1`.
  """
  def attach_opentelemetry(options \\ []) do
    if Keyword.keyword?(options),
      do: do_attach_opentelemetry(options),
      else: {:error, :invalid_opentelemetry_options}
  end

  defp do_attach_opentelemetry(options) do
    tracer_id = Keyword.get(options, :tracer_id, :tay)
    handler_id = Keyword.get(options, :handler_id, {:tay, :opentelemetry})

    with true <- is_atom(tracer_id),
         {:module, :otel_telemetry} <- Code.ensure_loaded(:otel_telemetry) do
      configs = [
        {[:tay, :command, :start], %{type: :start, tracer_id: tracer_id}},
        {[:tay, :command, :stop], %{type: :stop, tracer_id: tracer_id}},
        {[:tay, :command, :exception], %{type: :exception, tracer_id: tracer_id}}
      ]

      attach_opentelemetry_handlers(configs, handler_id, [])
    else
      false -> {:error, :invalid_opentelemetry_options}
      {:error, _} -> {:error, :opentelemetry_telemetry_not_available}
    end
  end

  @doc "Detaches handlers installed by `attach_opentelemetry/1`."
  def detach_opentelemetry(handler_id \\ {:tay, :opentelemetry}) do
    Enum.each([:start, :stop, :exception], &:telemetry.detach({handler_id, &1}))
    :ok
  end

  @doc false
  def handle_opentelemetry(_event, _measurements, metadata, %{
        type: :start,
        tracer_id: tracer_id
      }) do
    operation = Map.fetch!(metadata, :operation)

    apply(:otel_telemetry, :start_telemetry_span, [
      tracer_id,
      "tay.#{operation}",
      metadata,
      %{
        attributes: %{
          :"tay.engine" => label(metadata.engine),
          :"tay.operation" => Atom.to_string(operation)
        }
      }
    ])

    :ok
  end

  def handle_opentelemetry(_event, _measurements, metadata, %{
        type: :stop,
        tracer_id: tracer_id
      }) do
    span = apply(:otel_telemetry, :set_current_telemetry_span, [tracer_id, metadata])

    if span != :undefined do
      apply(:otel_span, :set_attribute, [
        span,
        :"tay.outcome",
        metadata |> Map.fetch!(:outcome) |> Atom.to_string()
      ])
    end

    apply(:otel_telemetry, :end_telemetry_span, [tracer_id, metadata])
  end

  def handle_opentelemetry(event, measurements, metadata, config) do
    apply(:otel_telemetry, :handle_event, [event, measurements, metadata, config])
  end

  @doc "Emits one bounded metrics snapshot for an engine."
  def emit_snapshot(engine \\ Tay.Engine, timeout \\ 1_000) do
    status = Tay.status(name: engine)

    with state when state != :unavailable <- status.state,
         {:ok, stats} <- Tay.stats(name: engine, timeout: timeout),
         {:ok, queues} <- Tay.queues(name: engine, timeout: timeout),
         {:ok, schedules} <- Tay.schedules(name: engine, timeout: timeout) do
      schedule_counts = Enum.frequencies_by(schedules, &schedule_state/1)

      :telemetry.execute(@engine_availability_event, %{up: 1}, %{engine: engine})

      measurements =
        status
        |> Map.take([
          :jobs,
          :blocked_jobs,
          :running_executions,
          :unsettled_executions,
          :state_bytes_charged,
          :canonical_history_bytes,
          :segment_count,
          :client_slots_used,
          :client_slots
        ])
        |> Map.merge(stats)
        |> Map.merge(%{
          active_schedules: Map.get(schedule_counts, :active, 0),
          cancelled_schedules: Map.get(schedule_counts, :cancelled, 0)
        })

      :telemetry.execute(@engine_snapshot_event, measurements, %{engine: engine})

      Enum.each(queues, fn queue ->
        :telemetry.execute(
          @queue_snapshot_event,
          %{
            jobs: queue.jobs,
            executing: queue.executing,
            concurrency: queue.concurrency,
            paused: if(queue.paused, do: 1, else: 0)
          },
          %{engine: engine, queue: queue.key}
        )
      end)

      :ok
    else
      _ -> unavailable_snapshot(engine)
    end
  catch
    _, _ -> unavailable_snapshot(engine)
  end

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
  def schedule_transition(engine, operation, schedule_id) do
    :telemetry.execute(@schedule_event, %{count: 1}, %{
      engine: engine,
      operation: operation,
      schedule_id: schedule_id
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

  defp schedule_state(%{cancelled_at: nil}), do: :active
  defp schedule_state(_), do: :cancelled

  defp label(value) when is_atom(value), do: Atom.to_string(value)
  defp label(value), do: inspect(value, limit: 10, printable_limit: 100)

  defp attach_opentelemetry_handlers([], _handler_id, _attached), do: :ok

  defp attach_opentelemetry_handlers([{event, config} | rest], handler_id, attached) do
    id = {handler_id, List.last(event)}

    case :telemetry.attach(id, event, &__MODULE__.handle_opentelemetry/4, config) do
      :ok ->
        attach_opentelemetry_handlers(rest, handler_id, [id | attached])

      {:error, _} = error ->
        Enum.each(attached, &:telemetry.detach/1)
        error
    end
  end

  defp unavailable_snapshot(engine) do
    :telemetry.execute(@engine_availability_event, %{up: 0}, %{engine: engine})
    :ok
  end
end
