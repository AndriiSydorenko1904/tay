defmodule Tay.Dashboard.Router do
  @moduledoc "Router integration for the Tay dashboard."

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
