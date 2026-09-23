defmodule Tay.Dashboard.LiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R

  @endpoint Tay.Dashboard.TestEndpoint
  @engine Tay.Dashboard.TestEngine

  defmodule FailingWorker do
    use Tay.Worker, key: "dashboard.fail.v1", max_attempts: 1
    @impl true
    def perform(_job), do: {:error, :expected_failure}
  end

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Tay.Dashboard.TestPubSub})
    start_supervised!(@endpoint)
    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "mounts overview and updates from lifecycle telemetry", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @engine)
    {:ok, view, html} = live(build_conn(), "/tay/")
    assert html =~ "Overview"
    assert html =~ "Available"

    {:ok, job} = EngineWorker.new(%{"safe" => "value"}) |> Tay.insert(name: @engine)
    assert job.state == :available
    assert render(view) =~ ~r/Available.*1/s
    EngineHelpers.stop(root)
  end

  test "lists, filters, paginates, shows details, and cancels", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @engine)

    jobs =
      for n <- 1..52 do
        {:ok, job} = EngineWorker.new(%{"number" => n}) |> Tay.insert(name: @engine)
        job
      end

    {:ok, list, html} = live(build_conn(), "/tay/jobs")
    assert html =~ "v0.9.5"
    assert html =~ "Next page"
    assert length(Floki.find(Floki.parse_document!(render(list)), "#jobs tr")) == 50

    first_page_ids = job_ids(render(list))
    redirect = list |> element("#next-page") |> render_click()
    assert {:error, {:redirect, %{to: next_path}}} = redirect
    assert next_path =~ ~r|^/tay/jobs\?cursor=|
    {:ok, second_page, second_html} = live(build_conn(), next_path)
    assert second_html =~ "Page 2"
    assert length(job_ids(second_html)) == 2

    assert MapSet.disjoint?(
             MapSet.new(first_page_ids),
             MapSet.new(job_ids(render(second_page)))
           )

    html =
      render_change(second_page, "filter", %{"state" => "available", "queue" => "default"})

    assert html =~ "available"
    assert_patch(second_page, "/tay/jobs?queue=default&state=available")
    assert length(job_ids(html)) == 50

    html = render_change(second_page, "filter", %{"worker" => "worker."})
    assert_patch(second_page, "/tay/jobs?worker=worker.")
    assert html =~ "Worker key contains"
    assert length(job_ids(html)) == 50

    selected = List.last(jobs)
    {:ok, detail, html} = live(build_conn(), "/tay/jobs/#{selected.id}")
    assert html =~ selected.id
    assert html =~ "number"
    assert has_element?(detail, "button", "Cancel")

    assert render_click(detail, "cancel") =~ "cancelled"
    assert {:ok, %{state: :cancelled}} = Tay.get_job(selected.id, name: @engine)
    EngineHelpers.stop(root)
  end

  test "queue controls and malformed parameters are safe", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @engine)
    {:ok, queues, html} = live(build_conn(), "/tay/queues")
    assert html =~ "default"
    assert render_click(queues, "pause", %{"queue" => "default"}) =~ "paused"
    assert render_click(queues, "resume", %{"queue" => "default"}) =~ "running"

    {:ok, _view, html} = live(build_conn(), "/tay/jobs?state=not-an-atom&cursor=bad")
    assert html =~ "invalid"

    {:ok, _view, html} = live(build_conn(), "/tay/jobs/not-an-id")
    assert html =~ "invalid"
    EngineHelpers.stop(root)
  end

  test "retry action uses the public revision-checked API", %{path: path} do
    {:ok, root} =
      EngineHelpers.start(path, @engine,
        workers: %{"dashboard.fail.v1" => FailingWorker},
        queues: [default: 1],
        test_execution: true
      )

    {:ok, intent} = FailingWorker.new(%{"failure" => "bounded"})
    {:ok, _} = Tay.insert(intent, name: @engine)

    discarded =
      EngineHelpers.eventually(fn ->
        case Tay.get_job(intent.id, name: @engine) do
          {:ok, %{state: :discarded} = job} -> job
          _ -> nil
        end
      end)

    assert discarded.state == :discarded
    assert :ok = Tay.pause_queue(:default, name: @engine)
    {:ok, detail, _html} = live(build_conn(), "/tay/jobs/#{intent.id}")
    assert has_element?(detail, "button", "Retry")
    assert render_click(detail, "retry") =~ "available"
    assert {:ok, %{state: :available}} = Tay.get_job(intent.id, name: @engine)
    EngineHelpers.stop(root)
  end

  test "engine unavailable renders an ordinary error" do
    {:ok, _view, html} = live(build_conn(), "/tay/")
    assert html =~ "unavailable"
  end

  defp job_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#jobs tr")
    |> Enum.map(fn row -> row |> Floki.attribute("id") |> List.first() end)
  end
end
