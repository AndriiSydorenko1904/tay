defmodule Tay.Dashboard.Router do
  @moduledoc """
  Phoenix router integration for Tay Dashboard.

  Import this module into a Phoenix router and call `tay_dashboard/2` inside a
  scope. The surrounding pipeline must provide sessions, LiveView support, and
  the application's administrator access policy.
  """

  @doc """
  Mounts Tay Dashboard at `path`.

  The optional `:engine` value is the registered name of the Tay Engine to
  inspect. It defaults to `Tay.default_name/0`. No other option is accepted.

      scope "/admin" do
        pipe_through [:browser, :require_admin]
        tay_dashboard "/tay", engine: MyApp.TayEngine
      end

  The macro creates overview, job list, job detail, and queue routes. It does
  not create or modify a pipeline and does not provide authentication.
  """
  defmacro tay_dashboard(path, options \\ []) do
    unless Keyword.keyword?(options) and
             length(options) == length(Enum.uniq(Keyword.keys(options))) and
             Enum.all?(Keyword.keys(options), &(&1 == :engine)) do
      raise ArgumentError, "tay_dashboard accepts only the :engine option"
    end

    engine = Keyword.get_lazy(options, :engine, &Tay.default_name/0)

    quote do
      import Phoenix.LiveView.Router

      scope unquote(path), alias: false, as: "tay_dashboard" do
        live_session :tay_dashboard,
          session: %{
            "tay_engine" => unquote(engine),
            "tay_dashboard_path" => unquote(path)
          } do
          live "/", Tay.Dashboard.OverviewLive, :index
          live "/jobs", Tay.Dashboard.JobsLive, :index
          live "/jobs/:id", Tay.Dashboard.JobLive, :show
          live "/queues", Tay.Dashboard.QueuesLive, :index
        end
      end
    end
  end
end
