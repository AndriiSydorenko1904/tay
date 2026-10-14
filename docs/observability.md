# Metrics and OpenTelemetry

Tay emits backend-neutral `:telemetry` events and ships a ready-made
`Telemetry.Metrics` catalogue. Tay does not start a public metrics endpoint or
an OpenTelemetry SDK: the host application keeps ownership of network exposure,
authentication, resource attributes, sampling, processors, and exporters.

## Supervision

Add the gauge poller beside each Tay engine. The poller uses only bounded public
inspection APIs and reports `tay.engine.up = 0` while an engine is unavailable.
It never scans retained history.

```elixir
children = [
  {Tay, name: MyApp.Tay, data_dir: "/var/lib/my_app/tay"},
  Tay.Telemetry.poller_child_spec(
    id: MyApp.TayMetricsPoller,
    engines: [MyApp.Tay],
    period: 10_000,
    timeout: 1_000
  )
]
```

Use distinct poller `:id` values when a supervision tree starts more than one
poller. A single poller can probe multiple atom-named engines.

## Prometheus

Add the reporter to the host application's dependencies:

```elixir
{:telemetry_metrics_prometheus, "~> 1.1"}
```

Then supervise its reporter with Tay's catalogue:

```elixir
children = [
  Tay.Telemetry.poller_child_spec(engines: [MyApp.Tay]),
  {TelemetryMetricsPrometheus,
   metrics: Tay.Telemetry.metrics(),
   port: 9_568}
]
```

The reporter exposes `/metrics`. Bind and expose that endpoint only on a trusted
operations network. If the application already owns an HTTP endpoint, it may
instead run `TelemetryMetricsPrometheus.Core` and route the scrape response
itself.

Prometheus converts dotted catalogue names to conventional underscore names.
For example, `tay.command.duration.seconds` becomes a duration histogram and
`tay.engine.up` is the availability gauge.

## OpenTelemetry

Public Tay calls emit the standard span event triplet:

- `[:tay, :command, :start]`
- `[:tay, :command, :stop]`
- `[:tay, :command, :exception]`

The metadata contains only `:engine`, `:operation`, and the finite `:outcome`
on completion. Install `opentelemetry_telemetry` in the host application and
attach Tay after the OpenTelemetry SDK has started:

```elixir
{:opentelemetry_api, "~> 1.5"},
{:opentelemetry, "~> 1.7"},
{:opentelemetry_exporter, "~> 1.10"},
{:opentelemetry_telemetry, "~> 1.1"}
```

```elixir
:ok = Tay.Telemetry.attach_opentelemetry(tracer_id: :my_app)
```

The bridge creates spans such as `tay.insert`, adds bounded `tay.engine`,
`tay.operation`, and `tay.outcome` attributes, and preserves any current parent span.
The host still configures OTLP and sampling. Detach it during custom runtime
reconfiguration with `Tay.Telemetry.detach_opentelemetry/0`.

For metrics through an OpenTelemetry Collector, point its Prometheus receiver
at the Tay reporter and export that metrics pipeline through OTLP:

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: tay
          static_configs:
            - targets: ["app:9568"]

exporters:
  otlp:
    endpoint: observability-backend:4317

service:
  pipelines:
    metrics:
      receivers: [prometheus]
      exporters: [otlp]
```

## Catalogue and cardinality

`Tay.Telemetry.metrics/0` covers command counts/latency, job/queue/schedule
transitions, group-commit batch size and latency, job-state gauges, running and
unsettled execution counts, state/history bytes, segment count, admission-slot
use, schedule counts, and per-queue jobs/execution/concurrency/pause state.

Metric labels are intentionally bounded to configured engine/queue names and
finite operation/state/outcome values. Raw lifecycle events retain `job_id` or
`schedule_id` for targeted diagnostics, but Tay's metric catalogue never uses
those values as labels. Arguments, results, failures, schedule definitions,
storage paths, and worker payloads are never telemetry metadata.

Call `Tay.Telemetry.events/0` to enumerate the stable event names. Custom
handlers execute synchronously in the emitting process, so they must remain
fast and must not perform blocking network I/O.
