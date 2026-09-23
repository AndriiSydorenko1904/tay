defmodule Tay.Dashboard.Standalone.PageController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  def home(conn, _params), do: redirect(conn, to: "/tay")
end
