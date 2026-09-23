defmodule Tay.Dashboard.Standalone.HTTPTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint Tay.Dashboard.Standalone.Endpoint

  test "requires authentication for the dashboard" do
    conn = get(build_conn(), "/tay")
    assert conn.status == 401
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") != []
  end

  test "allows trusted-network access when Basic Auth is not configured" do
    auth = Application.get_env(:tay_dashboard_standalone, :basic_auth)
    Application.delete_env(:tay_dashboard_standalone, :basic_auth)
    on_exit(fn -> Application.put_env(:tay_dashboard_standalone, :basic_auth, auth) end)

    conn = get(build_conn(), "/tay")
    assert html_response(conn, 200) =~ "Tay Dashboard"
  end

  test "serves a complete LiveView page and client assets" do
    conn =
      build_conn()
      |> put_req_header(
        "authorization",
        Plug.BasicAuth.encode_basic_auth("admin", "test-password")
      )
      |> get("/tay")

    assert html_response(conn, 200) =~ "Tay Dashboard"
    assert conn.resp_body =~ ~s(src="/assets/phoenix.min.js")
    assert conn.resp_body =~ ~s(src="/assets/phoenix_live_view.min.js")

    assert get(build_conn(), "/assets/phoenix.min.js").status == 200
    assert get(build_conn(), "/assets/phoenix_live_view.min.js").status == 200
  end
end
