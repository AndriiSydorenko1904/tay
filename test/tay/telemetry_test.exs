defmodule :otel_telemetry do
  def start_telemetry_span(tracer_id, span_name, _metadata, options) do
    Process.put(:tay_otel_start, {tracer_id, span_name, options})
    :tay_test_span
  end

  def set_current_telemetry_span(tracer_id, _metadata) do
    Process.put(:tay_otel_current, tracer_id)
    :tay_test_span
  end

  def end_telemetry_span(tracer_id, _metadata) do
    Process.put(:tay_otel_end, tracer_id)
    :ok
  end

  def handle_event(_, _, _, _), do: :ok
end

defmodule :otel_span do
  def set_attribute(span, key, value) do
    Process.put(:tay_otel_attribute, {span, key, value})
    true
  end
end

defmodule Tay.TelemetryTest do
  use ExUnit.Case, async: false

  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: Recovery

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    Recovery.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "metric catalogue is backend-neutral and excludes identifier labels" do
    metrics = Tay.Telemetry.metrics()

    assert Enum.any?(metrics, &(&1.name == [:tay, :command, :duration, :seconds]))
    assert Enum.any?(metrics, &(&1.name == [:tay, :engine, :up]))
    assert Enum.any?(metrics, &(&1.name == [:tay, :queue, :jobs]))

    refute Enum.any?(metrics, fn metric ->
             :job_id in metric.tags or :schedule_id in metric.tags
           end)

    assert Enum.all?(
             Enum.filter(metrics, &match?(%Telemetry.Metrics.Distribution{}, &1)),
             &Keyword.has_key?(&1.reporter_options, :buckets)
           )

    assert [:tay, :command, :start] in Tay.Telemetry.events()
    assert [:tay, :engine, :snapshot] in Tay.Telemetry.events()
    assert [:tay, :engine, :availability] in Tay.Telemetry.events()
  end

  test "metric catalogue starts and scrapes with the Prometheus reporter" do
    name = Tay.TelemetryTest.Prometheus

    assert {:ok, _pid} =
             start_supervised(
               {TelemetryMetricsPrometheus.Core,
                metrics: Tay.Telemetry.metrics(), name: name, start_async: false}
             )

    :telemetry.execute([:tay, :engine, :availability], %{up: 1}, %{engine: @name})
    scrape = TelemetryMetricsPrometheus.Core.scrape(name)

    assert scrape =~ "tay_engine_up"
    assert scrape =~ "engine=\"Elixir.Tay.TelemetryTest\""
  end

  test "public commands emit payload-free span events", %{path: path} do
    parent = self()
    handler = "command-span-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:tay, :command, :start], [:tay, :command, :stop]],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, root} = EngineHelpers.start(path, @name, start_paused: true)

    assert {:ok, _job} = EngineWorker.new(%{"secret" => "never emit"}) |> Tay.insert(name: @name)

    assert_receive {:telemetry, [:tay, :command, :start], start_measurements,
                    %{engine: @name, operation: :insert} = start_metadata}

    assert is_integer(start_measurements.system_time)
    refute Map.has_key?(start_metadata, :job_id)
    refute inspect(start_metadata) =~ "never emit"

    assert_receive {:telemetry, [:tay, :command, :stop], %{duration: duration},
                    %{engine: @name, operation: :insert, outcome: :ok} = stop_metadata}

    assert is_integer(duration) and duration >= 0
    refute inspect(stop_metadata) =~ "never emit"
    EngineHelpers.stop(root)
  end

  test "snapshot emits engine and configured queue gauges", %{path: path} do
    parent = self()
    handler = "snapshot-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:tay, :engine, :availability],
          [:tay, :engine, :snapshot],
          [:tay, :queue, :snapshot]
        ],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, root} = EngineHelpers.start(path, @name, start_paused: true)
    assert {:ok, _} = EngineWorker.new(%{"n" => 1}) |> Tay.insert(name: @name)

    assert :ok = Tay.Telemetry.emit_snapshot(@name)

    assert_receive {:telemetry, [:tay, :engine, :availability], %{up: 1}, %{engine: @name}}
    assert_receive {:telemetry, [:tay, :engine, :snapshot], measurements, %{engine: @name}}
    assert measurements.jobs == 1
    assert measurements.available == 1
    assert measurements.active_schedules == 0

    assert_receive {:telemetry, [:tay, :queue, :snapshot],
                    %{jobs: 1, executing: 0, concurrency: 10, paused: 1},
                    %{engine: @name, queue: "default"}}

    EngineHelpers.stop(root)

    assert :ok = Tay.Telemetry.emit_snapshot(@name, 10)
    assert_receive {:telemetry, [:tay, :engine, :availability], %{up: 0}, %{engine: @name}}
  end

  test "poller validates its bounded engine list" do
    assert {:error, {:invalid_telemetry_poller_options, _child}} =
             start_supervised({Tay.Telemetry.Poller, engines: [], period: 10})

    assert {:ok, pid} =
             start_supervised(
               Tay.Telemetry.poller_child_spec(
                 id: :telemetry_test_poller,
                 engines: [@name],
                 period: 10,
                 timeout: 10
               )
             )

    assert Process.alive?(pid)
  end

  test "OpenTelemetry bridge validates options and maps command spans", %{path: path} do
    assert {:error, :invalid_opentelemetry_options} =
             Tay.Telemetry.attach_opentelemetry(:invalid)

    assert :ok = Tay.Telemetry.attach_opentelemetry(tracer_id: :tay_test)
    on_exit(fn -> Tay.Telemetry.detach_opentelemetry() end)

    {:ok, root} = EngineHelpers.start(path, @name, start_paused: true)
    assert {:ok, _} = EngineWorker.new(%{}) |> Tay.insert(name: @name)

    assert {:tay_test, "tay.insert", %{attributes: attributes}} =
             Process.get(:tay_otel_start)

    assert attributes[:"tay.engine"] == Atom.to_string(@name)
    assert attributes[:"tay.operation"] == "insert"
    assert Process.get(:tay_otel_current) == :tay_test
    assert Process.get(:tay_otel_attribute) == {:tay_test_span, :"tay.outcome", "ok"}
    assert Process.get(:tay_otel_end) == :tay_test

    EngineHelpers.stop(root)
  end

  test "operational gauges convert milliseconds to seconds and capacity reasons stay bounded" do
    name = Tay.TelemetryTest.OperationalPrometheus

    assert {:ok, _} =
             start_supervised(
               {TelemetryMetricsPrometheus.Core,
                metrics: Tay.Telemetry.metrics(), name: name, start_async: false}
             )

    :telemetry.execute([:tay, :queue, :snapshot], %{oldest_ready_age_ms: 1500}, %{
      engine: @name,
      queue: "default"
    })

    :telemetry.execute(
      [:tay, :engine, :snapshot],
      %{schedule_lag_ms: 2500, last_checkpoint_at_ms: 1_700_000_000_000},
      %{engine: @name}
    )

    Tay.Telemetry.capacity_refused(@name, :insert, :client_slots)
    Tay.Telemetry.capacity_refused(@name, :insert, {:private, "sensitive"})
    scrape = TelemetryMetricsPrometheus.Core.scrape(name)
    assert scrape =~ ~r/tay_queue_oldest_ready_age_seconds\{[^}]+\} 1.5/
    assert scrape =~ ~r/tay_schedule_lag_seconds\{[^}]+\} 2.5/
    assert scrape =~ "tay_storage_last_checkpoint_timestamp_seconds"
    assert scrape =~ "tay_capacity_refused_count"
    assert scrape =~ ~s(reason="client_slots")
    assert scrape =~ ~s(reason="other")
    refute scrape =~ "sensitive"
  end
end
