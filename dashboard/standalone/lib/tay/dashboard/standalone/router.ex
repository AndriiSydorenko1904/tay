defmodule Tay.Dashboard.Standalone.Router do
  @moduledoc false

  use Phoenix.Router
  import Tay.Dashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:authenticate)
    plug(:put_root_layout, html: {Tay.Dashboard.Standalone.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)

    get("/", Tay.Dashboard.Standalone.PageController, :home)
    tay_dashboard("/tay")
  end

  defp authenticate(conn, _options) do
    case Application.get_env(:tay_dashboard_standalone, :basic_auth) do
      %{username: username, password: password} ->
        Plug.BasicAuth.basic_auth(conn,
          username: username,
          password: password,
          realm: "Tay Dashboard"
        )

      nil ->
        conn
    end
  end
end
