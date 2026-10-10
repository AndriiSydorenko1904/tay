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

  test "dashboard telemetry coalesces refreshes until the view acknowledges them" do
    signal = :atomics.new(1, [])
    config = %{pid: self(), engine: @engine, refresh_signal: signal}
    metadata = %{engine: @engine}

    for _ <- 1..100,
        do: Tay.Dashboard.Live.handle_telemetry([], %{}, metadata, config)

    assert_receive {:tay_dashboard_refresh, ^signal}
    refute_receive {:tay_dashboard_refresh, ^signal}

    :ok = Tay.Dashboard.Live.acknowledge_refresh(signal)
    Tay.Dashboard.Live.handle_telemetry([], %{}, metadata, config)
    assert_receive {:tay_dashboard_refresh, ^signal}
  end

  test "mounts overview and updates from lifecycle telemetry", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @engine)
    {:ok, view, html} = live(build_conn(), "/tay/")
    assert html =~ "Overview"
    assert html =~ "Available"
    assert html =~ "Toggle color theme"
    assert html =~ "document.documentElement.dataset.tayTheme"
    assert html =~ ~s(html[data-tay-theme="dark"] #tay-dashboard)
    refute html =~ ~s(#tay-dashboard[data-theme="dark"])
    assert html =~ "Run compaction"
    assert html =~ "Stored job history"
    assert html =~ "MiB"
    assert html =~ "Finished-job retention"
    assert html =~ "24 h"
    assert html =~ "Application memory"
    assert html =~ "Total runtime memory"
    assert html =~ "Fast lookup tables (ETS)"
    assert html =~ "Shared data buffers"
    assert html =~ "Job data safeguards"
    assert html =~ "Active jobs"
    assert html =~ "Finished job history"
    assert html =~ "Active job memory budget"
    assert html =~ "all converted into one byte budget"
    assert has_element?(view, ".cards + .section-note")
    refute html =~ "Structured values"
    refute html =~ "2,000,000"
    assert html =~ "Storage files (1 shown)"
    assert html =~ "00000000000000000001.tay"
    assert html =~ "active"

    for state <- Tay.Dashboard.Live.states() do
      name = Atom.to_string(state)

      assert has_element?(
               view,
               "a#job-state-#{name}[href='/tay/jobs?state=#{name}'][aria-label='View #{name} jobs']"
             )
    end

    refute has_element?(view, "#storage-segments[open]")
    view |> element("#storage-segments summary") |> render_click()
    assert has_element?(view, "#storage-segments[open]")

    {:ok, job} = EngineWorker.new(%{"safe" => "value"}) |> Tay.insert(name: @engine)
    assert job.state == :available

    assert EngineHelpers.eventually(fn ->
             render(view) =~ ~r/Available.*1/s
           end)

    assert has_element?(view, "#storage-segments[open]")

    assert render_click(view, "prepare-compaction") =~ "cannot be recovered"
    assert has_element?(view, "#confirm-compaction")
    assert has_element?(view, "#terminal-retention-hours[value='24']")
    assert has_element?(view, "#terminal-retention-hours[min='0']")

    assert render_submit(view, "compact", %{"terminal_retention_hours" => "0"}) =~
             "Compaction is running in the background"

    assert EngineHelpers.eventually(fn -> has_element?(view, "#compaction-result") end)
    assert render(view) =~ "Compaction completed"
    assert render(view) =~ "Future finished-job retention is 1 h"
    EngineHelpers.stop(root)
  end

  test "job status cards navigate to the matching jobs filter", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @engine)
    {:ok, view, _html} = live(build_conn(), "/tay/")

    assert {:error, {:live_redirect, %{to: "/tay/jobs?state=completed"}}} =
             view |> element("#job-state-completed") |> render_click()

    EngineHelpers.stop(root)
  end

  test "formats dashboard byte values using readable binary units", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @engine, max_state_bytes: 5 * 1_073_741_824)
    {:ok, view, html} = live(build_conn(), "/tay/")

    assert html =~ "0 B / 5 GiB"
    refute html =~ "5120.0 MiB"
    assert Tay.Dashboard.OverviewLive.format_bytes(round(0.14 * 1_048_576)) == "143.36 KiB"
    assert Tay.Dashboard.OverviewLive.format_bytes(5 * 1_073_741_824) == "5 GiB"
    assert has_element?(view, "#storage-segments")

    EngineHelpers.stop(root)
  end

  test "unavailable overview shows unknown values and recovers without a reload", %{path: path} do
    {:ok, view, html} = live(build_conn(), "/tay/")
    assert html =~ "Tay is temporarily unavailable for lifecycle maintenance or recovery"
    assert html =~ "Engine state: unavailable"
    assert has_element?(view, "#engine-unavailable")
    refute has_element?(view, "#prepare-compaction")

    {:ok, root} = EngineHelpers.start(path, @engine)

    assert EngineHelpers.eventually(fn ->
             html = render(view)
             html =~ "Active jobs" and not has_element?(view, "#engine-unavailable")
           end)

    assert has_element?(view, "#prepare-compaction")
    EngineHelpers.stop(root)
  end

  test "overview presents online compaction as live maintenance", %{path: path} do
    owner = self()
    gate = :atomics.new(1, [])

    hook = fn
      {:compaction, :base_write}, _native ->
        if :atomics.get(gate, 1) == 1 do
          send(owner, {:dashboard_compaction_preparing, self()})
          receive do: (:finish_dashboard_compaction -> :ok)
        end

        :ok

      _, _native ->
        :ok
    end

    {:ok, root} = EngineHelpers.start(path, @engine, writer_hook: hook)
    {:ok, intent} = EngineWorker.new(%{"retained" => true}, scheduled_at: 5_000_000)
    assert {:ok, _} = Tay.insert(intent, name: @engine)
    assert {:ok, _} = Tay.compact(name: @engine, timeout: 60_000)

    :atomics.put(gate, 1, 1)
    compact = Task.async(fn -> Tay.compact(name: @engine, timeout: 60_000) end)
    assert_receive {:dashboard_compaction_preparing, builder}, 5_000

    {:ok, view, html} = live(build_conn(), "/tay/")
    assert html =~ "Engine state: compacting (preparing)"
    assert html =~ "Jobs continue to be accepted and executed"
    assert has_element?(view, "#engine-compacting")
    refute has_element?(view, "#engine-unavailable")

    send(builder, :finish_dashboard_compaction)
    assert {:ok, _} = Task.await(compact, 60_000)
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
    assert html =~ "v#{Application.spec(:tay, :vsn)}"
    assert html =~ "Next page"
    assert html =~ "Last page"
    refute html =~ "Apply filters"
    assert html =~ "state-available"
    assert html =~ "Page 1 of 2 · showing 50 of 52 jobs"
    assert has_element?(list, "#job-filters[phx-update='ignore']")
    refute has_element?(list, "#first-page")
    refute has_element?(list, "#previous-page")
    last_path = html |> Floki.parse_document!() |> Floki.attribute("#last-page", "href") |> hd()
    assert length(Floki.find(Floki.parse_document!(render(list)), "#jobs tr")) == 50

    first_page_ids = job_ids(render(list))
    next_path = html |> Floki.parse_document!() |> Floki.attribute("#next-page", "href") |> hd()
    list |> element("#next-page") |> render_click()
    assert_patch(list, next_path)
    assert next_path =~ ~r|^/tay/jobs\?cursor=|
    second_page = list
    second_html = render(second_page)
    assert second_html =~ "Page 2"
    assert second_html =~ "Page 2 of 2 · showing 2 of 52 jobs"
    assert has_element?(second_page, "#first-page")
    assert has_element?(second_page, "#previous-page")
    refute has_element?(second_page, "#next-page")
    refute has_element?(second_page, "#last-page")
    assert length(job_ids(second_html)) == 2

    refresh_signal = :atomics.new(1, [])
    :atomics.put(refresh_signal, 1, 1)
    send(second_page.pid, {:tay_dashboard_refresh, refresh_signal})

    assert EngineHelpers.eventually(fn ->
             :atomics.get(refresh_signal, 1) == 0 and render(second_page) =~ "Page 2 of 2"
           end)

    previous_path =
      second_html |> Floki.parse_document!() |> Floki.attribute("#previous-page", "href") |> hd()

    assert MapSet.disjoint?(
             MapSet.new(first_page_ids),
             MapSet.new(job_ids(render(second_page)))
           )

    second_page |> element("#previous-page") |> render_click()
    assert_patch(second_page, previous_path)
    previous_page = second_page
    previous_html = render(previous_page)
    assert previous_html =~ "Page 1 of 2"
    assert job_ids(previous_html) == first_page_ids
    refute has_element?(previous_page, "#previous-page")

    {:ok, last_page, _html} = live(build_conn(), "/tay/jobs")
    last_page |> element("#last-page") |> render_click()
    assert_patch(last_page, last_path)
    last_html = render(last_page)
    assert last_html =~ "Page 2 of 2 · showing 2 of 52 jobs"

    {:ok, filter_page, _html} = live(build_conn(), "/tay/jobs")

    html =
      render_change(filter_page, "filter", %{"state" => "available", "queue" => "default"})

    assert html =~ "available"
    assert_patch(filter_page, "/tay/jobs?queue=default&state=available")
    assert length(job_ids(html)) == 50

    html = render_change(filter_page, "filter", %{"worker" => "worker."})
    assert_patch(filter_page, "/tay/jobs?worker=worker.")
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
    {:ok, detail, html} = live(build_conn(), "/tay/jobs/#{intent.id}")
    assert has_element?(detail, "button", "Retry")
    assert html =~ "Task reported a failure"
    assert html =~ "consult the worker logs"
    assert html =~ "Diagnostic code: 1"
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
