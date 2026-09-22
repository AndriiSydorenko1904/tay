defmodule Tay.Dashboard.TestRouter do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Tay.Dashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
  end

  scope "/" do
    pipe_through :browser
    tay_dashboard("/tay", engine: Tay.Dashboard.TestEngine)
  end
end

defmodule Tay.Dashboard.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :tay_dashboard

  @session_options [store: :cookie, key: "_tay_dashboard", signing_salt: "dashboard"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug Tay.Dashboard.TestRouter
end
