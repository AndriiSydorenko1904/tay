defmodule Tay.Dashboard.Live do
  @moduledoc false
  use Phoenix.Component
  alias Phoenix.LiveView.Socket

  def initialize(%Socket{} = socket, session) do
    engine = Map.get(session, "tay_engine", Tay.default_name())
    path = Map.get(session, "tay_dashboard_path", "/tay")

    socket =
      Phoenix.Component.assign(socket, engine: engine, dashboard_path: path, flash_error: nil)

    if Phoenix.LiveView.connected?(socket) do
      handler = "tay-dashboard-#{inspect(self())}"

      :ok =
        :telemetry.attach_many(
          handler,
          [[:tay, :job, :transition], [:tay, :queue, :control]],
          &__MODULE__.handle_telemetry/4,
          %{pid: self(), engine: engine}
        )

      Phoenix.Component.assign(socket, telemetry_handler: handler)
    else
      socket
    end
  end

  def terminate(socket) do
    if handler = socket.assigns[:telemetry_handler], do: :telemetry.detach(handler)
    :ok
  end

  def handle_telemetry(_event, _measurements, %{engine: engine}, %{pid: pid, engine: engine}),
    do: send(pid, :tay_dashboard_refresh)

  def handle_telemetry(_, _, _, _), do: :ok

  def error_message(%Tay.Error{kind: kind, reason: reason}), do: "#{kind}: #{inspect(reason)}"
  def error_message(:not_found), do: "Job was not found. It may have been compacted."
  def error_message(other), do: inspect(other)

  def state_param(value) do
    Map.get(
      %{
        "available" => :available,
        "scheduled" => :scheduled,
        "executing" => :executing,
        "retryable" => :retryable,
        "completed" => :completed,
        "cancelled" => :cancelled,
        "discarded" => :discarded
      },
      value
    )
  end

  def states,
    do: [:available, :scheduled, :executing, :retryable, :completed, :cancelled, :discarded]

  attr :current, :atom, required: true
  attr :path, :string, required: true
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div
      id="tay-dashboard"
      style="font-family: ui-sans-serif, system-ui; color: #17202a; max-width: 1180px; margin: 0 auto; padding: 24px;"
    >
      <style>
        #tay-dashboard a { color: #3157d5; text-decoration: none; }
        #tay-dashboard nav { display:flex; gap:8px; border-bottom:1px solid #dfe4ea; margin-bottom:24px; }
        #tay-dashboard nav a { padding:10px 14px; border-bottom:3px solid transparent; }
        #tay-dashboard nav a.active { color:#17202a; border-color:#3157d5; font-weight:650; }
        #tay-dashboard .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; }
        #tay-dashboard .card { border:1px solid #dfe4ea; border-radius:10px; padding:16px; background:#fff; }
        #tay-dashboard .count { font-size:28px; font-weight:700; margin-top:6px; }
        #tay-dashboard table { width:100%; border-collapse:collapse; font-size:14px; }
        #tay-dashboard th, #tay-dashboard td { text-align:left; padding:10px; border-bottom:1px solid #e8ebef; vertical-align:top; }
        #tay-dashboard th { color:#53606e; font-size:12px; text-transform:uppercase; }
        #tay-dashboard .badge { border-radius:999px; background:#edf1ff; padding:3px 8px; white-space:nowrap; }
        #tay-dashboard .error { background:#fff0f0; color:#8a1f1f; padding:12px; border-radius:8px; margin:12px 0; }
        #tay-dashboard .actions { display:flex; gap:8px; align-items:end; flex-wrap:wrap; margin:14px 0; }
        #tay-dashboard button { border:0; border-radius:6px; padding:8px 12px; background:#3157d5; color:white; cursor:pointer; }
        #tay-dashboard input, #tay-dashboard select { border:1px solid #cbd2d9; border-radius:6px; padding:8px; }
        #tay-dashboard pre { white-space:pre-wrap; overflow-wrap:anywhere; background:#f6f8fa; padding:14px; border-radius:8px; }
      </style>
      <header>
        <h1 style="margin-bottom:8px">Tay Dashboard</h1>
      </header>
      <nav>
        <a class={if @current == :overview, do: "active"} href={@path <> "/"}>Overview</a>
        <a class={if @current in [:jobs, :job], do: "active"} href={@path <> "/jobs"}>Jobs</a>
        <a class={if @current == :queues, do: "active"} href={@path <> "/queues"}>Queues</a>
      </nav>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
