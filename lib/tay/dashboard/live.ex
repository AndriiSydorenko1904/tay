defmodule Tay.Dashboard.Live do
  @moduledoc false
  use Phoenix.Component
  alias Phoenix.LiveView.Socket

  def initialize(%Socket{} = socket, session) do
    engine = Map.get(session, "tay_engine", Tay.default_name())
    path = Map.get(session, "tay_dashboard_path", "/tay")

    socket =
      Phoenix.Component.assign(socket,
        engine: engine,
        dashboard_path: path,
        flash_error: nil
      )

    if Phoenix.LiveView.connected?(socket) do
      handler = "tay-dashboard-#{inspect(self())}"
      refresh_signal = :atomics.new(1, [])

      :ok =
        :telemetry.attach_many(
          handler,
          [[:tay, :job, :transition], [:tay, :queue, :control]],
          &__MODULE__.handle_telemetry/4,
          %{pid: self(), engine: engine, refresh_signal: refresh_signal}
        )

      Phoenix.Component.assign(socket,
        telemetry_handler: handler,
        refresh_signal: refresh_signal,
        dashboard_refresh_timer: nil
      )
    else
      socket
    end
  end

  def terminate(socket) do
    if handler = socket.assigns[:telemetry_handler], do: :telemetry.detach(handler)
    if timer = socket.assigns[:dashboard_refresh_timer], do: Process.cancel_timer(timer)
    :ok
  end

  def handle_telemetry(
        _event,
        _measurements,
        %{engine: engine},
        %{pid: pid, engine: engine, refresh_signal: signal}
      ) do
    # Telemetry handlers run in the process emitting the event. Keep both that
    # process and the LiveView mailbox bounded during transition-heavy loads.
    if :atomics.compare_exchange(signal, 1, 0, 1) == :ok,
      do: send(pid, {:tay_dashboard_refresh, signal})
  end

  def handle_telemetry(_, _, _, _), do: :ok

  def acknowledge_refresh(signal) do
    :atomics.put(signal, 1, 0)
    :ok
  end

  def schedule_refresh(socket, signal) do
    if socket.assigns.dashboard_refresh_timer do
      socket
    else
      timer = Process.send_after(self(), {:tay_dashboard_refresh_tick, signal}, 500)
      Phoenix.Component.assign(socket, dashboard_refresh_timer: timer)
    end
  end

  def finish_refresh(socket, signal) do
    :ok = acknowledge_refresh(signal)
    Phoenix.Component.assign(socket, dashboard_refresh_timer: nil)
  end

  def error_message(%Tay.Error{kind: :capacity, reason: :operation_slot}),
    do: "Storage maintenance or another lifecycle operation is already in progress."

  def error_message(%Tay.Error{kind: :unavailable}),
    do:
      "Tay is temporarily unavailable for lifecycle maintenance or recovery. The dashboard will retry automatically."

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
    assigns = assign(assigns, :dashboard_version, Application.spec(:tay, :vsn))

    ~H"""
    <div
      id="tay-dashboard"
      style="font-family: ui-sans-serif, system-ui; max-width: 1180px; margin: 0 auto; padding: 24px;"
    >
      <style>
        #tay-dashboard {
          --tay-bg:#f7f9fc; --tay-surface:#fff; --tay-surface-muted:#f2f5f9;
          --tay-text:#17202a; --tay-muted:#65717e; --tay-border:#dfe4ea;
          --tay-link:#3157d5; --tay-primary:#3157d5; --tay-primary-hover:#2546b8;
          --tay-error-bg:#fff0f0; --tay-error-text:#8a1f1f;
          --tay-completed-bg:#d9fbe5; --tay-completed-text:#17663a;
          --tay-discarded-bg:#ffe1e3; --tay-discarded-text:#9b1c31;
          --tay-executing-bg:#dceaff; --tay-executing-text:#174ea6;
          --tay-retryable-bg:#ffedcc; --tay-retryable-text:#8a4b08;
          --tay-scheduled-bg:#eadfff; --tay-scheduled-text:#6035a8;
          --tay-neutral-bg:#ececef; --tay-neutral-text:#555b66;
          color:var(--tay-text); color-scheme:light;
        }
        html[data-tay-theme="dark"] #tay-dashboard {
          --tay-bg:#0d1117; --tay-surface:#161b22; --tay-surface-muted:#21262d;
          --tay-text:#e6edf3; --tay-muted:#9da7b3; --tay-border:#30363d;
          --tay-link:#78a9ff; --tay-primary:#4169e1; --tay-primary-hover:#5b7bec;
          --tay-error-bg:#3d171c; --tay-error-text:#ffb4b8;
          --tay-completed-bg:#173b2a; --tay-completed-text:#7ee2a8;
          --tay-discarded-bg:#4a1d27; --tay-discarded-text:#ff9ca8;
          --tay-executing-bg:#18375f; --tay-executing-text:#8fc0ff;
          --tay-retryable-bg:#493014; --tay-retryable-text:#ffc977;
          --tay-scheduled-bg:#35245a; --tay-scheduled-text:#c9acff;
          --tay-neutral-bg:#30363d; --tay-neutral-text:#c6ced7;
          color-scheme:dark;
        }
        @media (prefers-color-scheme: dark) {
          html:not([data-tay-theme]) #tay-dashboard {
            --tay-bg:#0d1117; --tay-surface:#161b22; --tay-surface-muted:#21262d;
            --tay-text:#e6edf3; --tay-muted:#9da7b3; --tay-border:#30363d;
            --tay-link:#78a9ff; --tay-primary:#4169e1; --tay-primary-hover:#5b7bec;
            --tay-error-bg:#3d171c; --tay-error-text:#ffb4b8;
            --tay-completed-bg:#173b2a; --tay-completed-text:#7ee2a8;
            --tay-discarded-bg:#4a1d27; --tay-discarded-text:#ff9ca8;
            --tay-executing-bg:#18375f; --tay-executing-text:#8fc0ff;
            --tay-retryable-bg:#493014; --tay-retryable-text:#ffc977;
            --tay-scheduled-bg:#35245a; --tay-scheduled-text:#c9acff;
            --tay-neutral-bg:#30363d; --tay-neutral-text:#c6ced7;
            color-scheme:dark;
          }
        }
        #tay-dashboard::before { content:""; position:fixed; inset:0; z-index:-1; background:var(--tay-bg); }
        #tay-dashboard a { color:var(--tay-link); text-decoration:none; }
        #tay-dashboard header { display:flex; align-items:center; justify-content:space-between; gap:16px; }
        #tay-dashboard .primary-nav { display:flex; gap:8px; border-bottom:1px solid var(--tay-border); margin-bottom:24px; }
        #tay-dashboard .primary-nav a { padding:10px 14px; border-bottom:3px solid transparent; }
        #tay-dashboard .primary-nav a.active { color:var(--tay-text); border-color:var(--tay-primary); font-weight:650; }
        #tay-dashboard .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; }
        #tay-dashboard .card { border:1px solid var(--tay-border); border-radius:10px; padding:16px; background:var(--tay-surface); }
        #tay-dashboard .job-state-card { display:block; color:inherit; transition:border-color .15s ease, box-shadow .15s ease, transform .15s ease; }
        #tay-dashboard .job-state-card:hover { color:inherit; border-color:var(--tay-primary); box-shadow:0 4px 14px rgba(0,0,0,.12); transform:translateY(-1px); }
        #tay-dashboard .job-state-card:focus-visible { color:inherit; outline:3px solid var(--tay-primary); outline-offset:2px; }
        #tay-dashboard .count { font-size:28px; font-weight:700; margin-top:6px; }
        #tay-dashboard .card-help { color:var(--tay-muted); font-size:12px; line-height:1.35; margin-top:8px; }
        #tay-dashboard .section-help { color:var(--tay-muted); margin-top:-4px; }
        #tay-dashboard .section-note { color:var(--tay-muted); margin:14px 0 0; }
        #tay-dashboard table { width:100%; border-collapse:collapse; font-size:14px; }
        #tay-dashboard th, #tay-dashboard td { text-align:left; padding:10px; border-bottom:1px solid var(--tay-border); vertical-align:top; }
        #tay-dashboard th { color:var(--tay-muted); font-size:12px; text-transform:uppercase; }
        #tay-dashboard .badge { border-radius:999px; padding:3px 8px; white-space:nowrap; font-weight:600; }
        #tay-dashboard .state-completed, #tay-dashboard .state-running { background:var(--tay-completed-bg); color:var(--tay-completed-text); }
        #tay-dashboard .state-discarded { background:var(--tay-discarded-bg); color:var(--tay-discarded-text); }
        #tay-dashboard .state-executing { background:var(--tay-executing-bg); color:var(--tay-executing-text); }
        #tay-dashboard .state-retryable { background:var(--tay-retryable-bg); color:var(--tay-retryable-text); }
        #tay-dashboard .state-scheduled { background:var(--tay-scheduled-bg); color:var(--tay-scheduled-text); }
        #tay-dashboard .state-available, #tay-dashboard .state-cancelled, #tay-dashboard .state-paused { background:var(--tay-neutral-bg); color:var(--tay-neutral-text); }
        #tay-dashboard .error { background:var(--tay-error-bg); color:var(--tay-error-text); padding:12px; border-radius:8px; margin:12px 0; }
        #tay-dashboard .notice { background:var(--tay-surface-muted); border:1px solid var(--tay-border); padding:12px; border-radius:8px; margin:12px 0; }
        #tay-dashboard .actions { display:flex; gap:8px; align-items:end; flex-wrap:wrap; margin:14px 0; }
        #tay-dashboard .pagination { align-items:center; }
        #tay-dashboard button { border:0; border-radius:6px; padding:8px 12px; background:var(--tay-primary); color:white; cursor:pointer; }
        #tay-dashboard button:hover { background:var(--tay-primary-hover); }
        #tay-dashboard button.secondary { background:var(--tay-surface-muted); color:var(--tay-text); border:1px solid var(--tay-border); }
        #tay-dashboard input, #tay-dashboard select { border:1px solid var(--tay-border); border-radius:6px; padding:8px; background:var(--tay-surface); color:var(--tay-text); }
        #tay-dashboard pre { white-space:pre-wrap; overflow-wrap:anywhere; background:var(--tay-surface-muted); padding:14px; border-radius:8px; }
        #tay-dashboard .outcome { border-left:4px solid var(--tay-border); padding:10px 12px; border-radius:4px; background:var(--tay-surface-muted); }
        #tay-dashboard .outcome-success { border-color:#2da44e; }
        #tay-dashboard .outcome-error { border-color:#cf394b; }
        #tay-dashboard .technical-details { margin-top:12px; color:var(--tay-muted); }
        #tay-dashboard .technical-details summary { cursor:pointer; }
      </style>
      <header>
        <h1 style="margin-bottom:8px">
          Tay Dashboard
          <small style="font-size:14px; color:var(--tay-muted); font-weight:500">v{@dashboard_version}</small>
        </h1>
        <button
          id="theme-toggle"
          type="button"
          class="secondary"
          aria-label="Toggle color theme"
          onclick="var h=document.documentElement,n=h.dataset.tayTheme==='dark'?'light':'dark';h.dataset.tayTheme=n;try{localStorage.setItem('tay-dashboard-theme',n)}catch(e){}"
        >◐ Theme</button>
      </header>
      <nav class="primary-nav">
        <a class={if @current == :overview, do: "active"} href={@path <> "/"}>Overview</a>
        <a class={if @current in [:jobs, :job], do: "active"} href={@path <> "/jobs"}>Jobs</a>
        <a class={if @current == :queues, do: "active"} href={@path <> "/queues"}>Queues</a>
      </nav>
      {render_slot(@inner_block)}
      <script>
        try { var t=localStorage.getItem('tay-dashboard-theme'); if(t!=='dark'&&t!=='light') t=matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'; document.documentElement.dataset.tayTheme=t } catch(e) {}
      </script>
    </div>
    """
  end
end
