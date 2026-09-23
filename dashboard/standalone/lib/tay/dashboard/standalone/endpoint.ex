defmodule Tay.Dashboard.Standalone.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :tay_dashboard_standalone

  @session_options [
    store: :cookie,
    key: "_tay_dashboard",
    signing_salt: "tay-dashboard-session",
    same_site: "Lax",
    http_only: true
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix, "priv/static"},
    only: ["phoenix.min.js"]
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    only: ["phoenix_live_view.min.js"]
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["text/*", "application/*"])
  plug(Plug.Session, @session_options)
  plug(Tay.Dashboard.Standalone.Router)
end
