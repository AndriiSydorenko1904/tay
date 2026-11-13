defmodule Tay.Executor.AuditRegressionsTest do
  use ExUnit.Case, async: false
  alias Tay.Test.{EngineHelpers, ExecutionHelpers, NativeHelpers}
  alias Tay.Executor.Server
  alias Tay.Engine.{Execution, Persistence}
  alias Tay.Storage.V2.{Completion, Reducer}
  alias Tay.Event

  @name __MODULE__
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install(System.system_time(:millisecond) + 10_000)
    path = NativeHelpers.path()

    socket =
      Path.join(Path.dirname(path), "audit-regression-#{System.unique_integer([:positive])}.sock")

    ExecutionHelpers.initialize(path)

    on_exit(fn ->
      File.rm(socket)
      File.rm_rf!(path)
    end)

    %{path: path, socket: socket}
  end

  defp start(path, socket, extra \\ []) do
    {:ok, root} =
      ExecutionHelpers.start(
        path,
        @name,
        Keyword.merge([workers: %{}, executor_socket: socket], extra)
      )

    Process.unlink(root)
    on_exit(fn -> stop(root) end)
    engine = EngineHelpers.engine(root)
    {root, engine, :sys.get_state(engine).executor_server}
  end

  defp stop(root) do
    try do
      EngineHelpers.stop(root)
    catch
      :exit, _ -> :ok
    end
  end

  defp success_was_written?(barrier), do: barrier == :post_append

  defp http_options(:http) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    [http_port: port]
  end

  defp http_options(_), do: []

  defp assert_http_server_rebound([]), do: :ok

  defp assert_http_server_rebound(http_port: port) do
    payload =
      Jason.encode!(%{runtime_id: "after-http-failure", tasks: ["audit.task"], capacity: 1})

    {output, 0} =
      System.cmd("curl", [
        "--noproxy",
        "*",
        "--silent",
        "--show-error",
        "--max-time",
        "2",
        "--header",
        "Content-Type: application/json",
        "--data",
        payload,
        "--write-out",
        "\n%{http_code}",
        "http://127.0.0.1:#{port}/workers"
      ])

    assert String.ends_with?(output, "\n201")
  end

  defp worker(server, task \\ "audit.task", queue \\ "default") do
    {:ok, token} = Server.register_http_worker(server, "audit-#{task}-#{queue}", [task], 1, queue)
    {:ok, pid, ^queue} = Server.http_worker(server, token)
    pid
  end

  defp complete(server, worker, result) do
    assert {:ok, message} = Tay.HTTP.WorkerSession.claim(worker)

    assert :ok =
             Server.complete(
               server,
               worker,
               message["reservation_id"],
               message["execution_id"],
               {:success, result}
             )

    message
  end

  test "atomic success has frozen bytes and rejects a stale execution token" do
    alias Tay.Test.EventHelpers, as: H

    {:ok, insert} =
      Tay.Storage.V2.Mutation.from_event(
        H.inserted(H.definition(%{"scheduled_at" => nil})),
        nil,
        1
      )

    {:ok, candidate} = Reducer.apply(Reducer.candidate(), insert)
    previous = candidate.jobs[H.id()]

    {:ok, started} =
      Tay.Storage.V2.Mutation.from_event(
        H.event(3, 10, 1, %{"attempt" => 1, "cycle_token" => 1}),
        previous,
        candidate.next_availability_order
      )

    {:ok, candidate} = Reducer.apply(candidate, started)
    job = candidate.jobs[H.id()]
    event = Completion.event(job, 11, %{"answer" => 42})

    payload =
      File.read!(Path.expand("../../fixtures/events/v2/success_atomic.hex", __DIR__))
      |> String.trim()
      |> Base.decode16!(case: :lower)

    assert {:ok, {14, 2, ^payload}} = Event.encode(event)
    assert {:ok, ^event, _} = Event.decode_payload(14, 2, payload, Tay.Event.Value.defaults())
    assert {:ok, next} = Reducer.apply_event(candidate, event, %{sequence: 100})
    assert next.jobs[job.id].revision == job.revision + 1
    assert next.jobs[job.id].state == :completed
    assert next.results[job.id].value == %{"answer" => 42}
    assert next.results[job.id].job_revision == next.jobs[job.id].revision
    stale = %{event | data: Map.put(event.data, "execution_token", 1)}
    assert {:error, :execution_conflict} = Reducer.apply_event(candidate, stale, %{sequence: 100})

    assert {:error, :invalid_event} =
             Event.encode(%{event | data: Map.put(event.data, "extra", nil)})

    refute Event.supported_schema?(14, 1)
  end

  for barrier <- [:pre_append, :post_append] do
    @barrier barrier
    test "crash at success #{@barrier} never recovers completed without its result", %{
      path: path,
      socket: socket
    } do
      owner = self()
      barrier = @barrier

      hook = fn
        {:execution, 4, ^barrier} ->
          send(owner, {:finish_barrier, self()})

          receive do
            :release -> :ok
          end

        _ ->
          :ok
      end

      {root, engine, server} = start(path, socket, test_hook: hook)
      worker = worker(server)
      {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name)
      complete(server, worker, %{"answer" => 42})
      assert_receive {:finish_barrier, ^engine}, 2_000
      Process.exit(engine, :kill)
      stop(root)
      {root, _, _} = start(path, socket)
      assert {:ok, recovered} = Tay.get_job(job.id, name: @name)

      if success_was_written?(barrier) do
        assert recovered.state == :completed
        assert Tay.result(job.id, name: @name) == {:ok, %{"answer" => 42}}
        assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000)
        assert Tay.result(job.id, name: @name) == {:ok, %{"answer" => 42}}
        stop(root)
        {_root, _, _} = start(path, socket)
        assert Tay.result(job.id, name: @name) == {:ok, %{"answer" => 42}}
      else
        assert recovered.state == :retryable
        assert Tay.result(job.id, name: @name) == :missing
      end
    end
  end

  test "resource refusal before START leaves the worker reservation free", %{
    path: path,
    socket: socket
  } do
    {:ok, seed} = EngineHelpers.start(path, @name, workers: %{}, executor_socket: socket)
    {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name)
    stop(seed)
    {_root, engine, server} = start(path, socket, max_history_bytes: 0)
    worker(server)

    :sys.replace_state(engine, fn state ->
      {next, _} = Execution.control({:queue, "default"}, state)
      next
    end)

    assert :sys.get_state(server).reservations == %{}
    assert Server.available_tasks(server, "default") == ["audit.task"]
    assert {:ok, %{state: :available}} = Tay.get_job(job.id, name: @name)
    assert :sys.get_state(engine).running == %{}
  end

  test "atomic completion is preserved in the online compaction delta", %{
    path: path,
    socket: socket
  } do
    owner = self()
    gate = :atomics.new(1, [])

    hook = fn
      {:compaction, :before_online_freeze}, _ ->
        if :atomics.compare_exchange(gate, 1, 1, 2) == :ok do
          send(owner, {:publisher_waiting, self()})

          receive do
            :release_publisher -> :ok
          end
        end

        :ok

      _, _ ->
        :ok
    end

    {root, engine, _server} = start(path, socket, writer_hook: hook, compaction: false)
    assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000)
    server = :sys.get_state(engine).executor_server
    worker = worker(server)
    {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name)
    assert {:ok, message} = Tay.HTTP.WorkerSession.claim(worker)
    :atomics.put(gate, 1, 1)
    compact = Task.async(fn -> Tay.compact(name: @name, timeout: 60_000) end)
    assert_receive {:publisher_waiting, publisher}, 5_000

    try do
      assert :ok =
               Server.complete(
                 server,
                 worker,
                 message["reservation_id"],
                 message["execution_id"],
                 {:success, %{"atomic" => true}}
               )

      assert EngineHelpers.eventually(fn ->
               Tay.result(job.id, name: @name) == {:ok, %{"atomic" => true}}
             end)
    after
      send(publisher, :release_publisher)
    end

    assert {:ok, _} = Task.await(compact, 60_000)
    refute :sys.get_state(:sys.get_state(@name).writer).delegate_read_open
    assert Tay.result(job.id, name: @name) == {:ok, %{"atomic" => true}}
    stop(root)
    {_root, _, _} = start(path, socket)
    assert Tay.result(job.id, name: @name) == {:ok, %{"atomic" => true}}
  end

  for outcome <- [:cancel, :failure, :timeout] do
    @outcome outcome
    test "#{outcome} releases the journal result reserve and worker capacity", %{
      path: path,
      socket: socket
    } do
      {_root, engine, server} = start(path, socket)
      worker = worker(server)
      {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name)
      assert {:ok, message} = Tay.HTTP.WorkerSession.claim(worker)
      assert :sys.get_state(engine).persistent_result_reserve > 0

      case @outcome do
        :cancel ->
          assert {:ok, _} = Tay.cancel(job.id, name: @name)

        :failure ->
          assert :ok =
                   Server.complete(
                     server,
                     worker,
                     message["reservation_id"],
                     message["execution_id"],
                     {:failure, %{}}
                   )

        :timeout ->
          entry = :sys.get_state(engine).running[{:executor, message["reservation_id"]}]
          send(engine, {:executor_timeout, entry.reservation, entry.execution})
      end

      assert EngineHelpers.eventually(fn ->
               :sys.get_state(engine).persistent_result_reserve == 0
             end)

      assert Server.available_tasks(server) == ["audit.task"]
      assert :sys.get_state(server).reservations == %{}
    end
  end

  test "result headroom cannot be consumed by new submissions while a job runs", %{
    path: path,
    socket: socket
  } do
    {_root, engine, server} = start(path, socket, max_history_bytes: 1_100_000)
    worker = worker(server)
    {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name)
    assert {:ok, message} = Tay.HTTP.WorkerSession.claim(worker)

    assert :sys.get_state(engine).persistent_result_reserve ==
             Persistence.result_history_reserve(:sys.get_state(engine).config)

    running = :sys.get_state(engine)

    expected_reserved =
      running.persistent_result_reserve +
        running.persistent_settlement_reserve * (1_024 + 64 + 44)

    assert EngineHelpers.eventually(fn ->
             Tay.status(name: @name).reserved_outcome_bytes == expected_reserved
           end)

    refusal =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        case Tay.enqueue("audit.unhandled", %{"padding" => String.duplicate("x", 30_000)},
               name: @name
             ) do
          {:ok, _} -> {:cont, nil}
          {:error, reason} -> {:halt, reason}
        end
      end)

    assert %Tay.Error{kind: :capacity, reason: :max_history_bytes} = refusal
    result = String.duplicate("x", 20_000)

    assert :ok =
             Server.complete(
               server,
               worker,
               message["reservation_id"],
               message["execution_id"],
               {:success, result}
             )

    assert EngineHelpers.eventually(fn -> Tay.result(job.id, name: @name) == {:ok, result} end)
    assert Process.alive?(engine)
    state = :sys.get_state(engine)
    assert state.persistent_result_reserve == 0
    assert Tay.State.Memory.used(state.memory) == state.budget.bytes + state.auxiliary_bytes
  end

  test "a journal smaller than the maximum result postpones START without losing capacity", %{
    path: path,
    socket: socket
  } do
    {_root, engine, server} = start(path, socket, max_history_bytes: 10_000)
    worker(server)
    {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name)

    :sys.replace_state(engine, fn state ->
      {next, _} = Execution.control({:queue, "default"}, state)
      next
    end)

    assert {:ok, %{state: :available}} = Tay.get_job(job.id, name: @name)
    assert Server.available_tasks(server) == ["audit.task"]
    assert :sys.get_state(server).reservations == %{}
    assert :sys.get_state(engine).persistent_result_reserve == 0
  end

  for durability <- [:persistent, :volatile] do
    @durability durability
    test "invalid #{@durability} results fail only their attempt using existing Engine limits", %{
      path: path,
      socket: socket
    } do
      options = []
      {root, engine, server} = start(path, socket, options)
      worker = worker(server)
      refute Map.has_key?(:sys.get_state(server), :value_limits)

      # JSON integers outside the durable Value range fail only their attempt.
      failed =
        for {result, retries, expected} <- [
              {-9_223_372_036_854_775_809, 1, :retryable},
              {18_446_744_073_709_551_616, 0, :discarded}
            ] do
          {:ok, job} =
            Tay.enqueue("audit.task", %{}, name: @name, retries: retries, durability: @durability)

          complete(server, worker, result)

          assert EngineHelpers.eventually(fn ->
                   match?({:ok, %{state: ^expected}}, Tay.get_job(job.id, name: @name))
                 end)

          assert Tay.status(name: @name).state == :ready
          assert Process.alive?(engine)
          assert Tay.result(job.id, name: @name) == :missing
          assert :sys.get_state(engine).persistent_result_reserve == 0
          assert :sys.get_state(server).reservations == %{}
          {job.id, expected}
        end

      {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name, durability: @durability)
      complete(server, worker, "fits")
      assert EngineHelpers.eventually(fn -> Tay.result(job.id, name: @name) == {:ok, "fits"} end)
      assert Tay.status(name: @name).state == :ready
      stop(root)
      {_root, _, _} = start(path, socket, options)

      if @durability == :persistent do
        for {id, expected} <- failed do
          assert {:ok, %{state: ^expected}} = Tay.get_job(id, name: @name)
          assert Tay.result(id, name: @name) == :missing
        end

        assert {:ok, %{state: :completed}} = Tay.get_job(job.id, name: @name)
        assert Tay.result(job.id, name: @name) == {:ok, "fits"}
      else
        for {id, _} <- failed ++ [{job.id, :completed}] do
          assert {:error, :not_found} = Tay.get_job(id, name: @name)
          assert Tay.result(id, name: @name) == :missing
        end
      end
    end
  end

  test "volatile successful results stay in memory and consume no journal reservation", %{
    path: path,
    socket: socket
  } do
    {root, engine, server} = start(path, socket, max_history_bytes: 0)
    worker = worker(server)
    {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name, durability: :volatile)
    complete(server, worker, nil)
    assert EngineHelpers.eventually(fn -> Tay.result(job.id, name: @name) == {:ok, nil} end)
    assert :sys.get_state(engine).persistent_result_reserve == 0
    stop(root)
    {_root, _, _} = start(path, socket)
    assert {:error, :not_found} = Tay.get_job(job.id, name: @name)
  end

  test "persistent result bodies remain on disk across checkpoints and restart", %{
    path: path,
    socket: socket
  } do
    {root, engine, server} =
      start(path, socket, compaction: false, executor_result_bytes: 262_144)

    assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
    worker = worker(server)
    value = %{"payload" => String.duplicate("r", 100_000)}
    {:ok, job} = Tay.enqueue("audit.task", %{}, name: @name)
    complete(server, worker, value)
    assert EngineHelpers.eventually(fn -> Tay.result(job.id, name: @name) == {:ok, value} end)
    {:ok, raw} = Tay.JobID.decode(job.id)
    assert %{cold_result: true} = :sys.get_state(engine).results[raw]
    refute Map.has_key?(:sys.get_state(engine).results[raw], :value)

    for _ <- 1..2 do
      assert {:ok, _} = Tay.compact(name: @name, terminal_retention: :infinity)
      assert {:ok, ^value} = Tay.result(job.id, name: @name)
    end

    stop(root)
    {_root, engine, _server} = start(path, socket, compaction: false)
    refute Map.has_key?(:sys.get_state(engine).results, raw)
    assert {:ok, ^value} = Tay.result(job.id, name: @name)
  end

  test "a worker in another queue cannot starve an eligible task", %{path: path, socket: socket} do
    {_root, _engine, server} = start(path, socket, queues: [a: 1, b: 1])
    worker(server, "audit.a", "a")
    worker(server, "audit.b", "b")
    {:ok, older} = Tay.enqueue("audit.a", %{}, name: @name, queue: "b")
    {:ok, later} = Tay.enqueue("audit.b", %{}, name: @name, queue: "b")

    assert EngineHelpers.eventually(fn ->
             match?({:ok, %{state: :executing}}, Tay.get_job(later.id, name: @name))
           end)

    assert {:ok, %{state: :available}} = Tay.get_job(older.id, name: @name)
  end

  test "HTTP IDs decode exactly once and cannot cancel the percent-encoded neighbour", %{
    path: path,
    socket: socket
  } do
    {_root, _, server} = start(path, socket)
    options = %{engine_name: @name, executor_server: server, max_body_bytes: 1_048_576}

    for id <- ["audit/report", "audit%2Freport", "звіт %"] do
      fields = %{
        "declaration_id" => id,
        "task" => "audit.task",
        "every" => %{"hours" => 1},
        "delay" => 3600
      }

      assert {:ok, _} = Server.register_schedule(server, fields)
      url = "/schedules/" <> URI.encode(id, &URI.char_unreserved?/1)
      conn = Plug.Test.conn(:get, url) |> Tay.HTTP.Router.call(options)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["schedule"]["id"] == id
    end

    conn = Plug.Test.conn(:delete, "/schedules/audit%2Freport") |> Tay.HTTP.Router.call(options)
    assert conn.status == 200
    assert {:ok, %{cancelled_at: at}} = Tay.get_schedule("audit/report", name: @name)
    assert is_integer(at)
    assert {:ok, %{cancelled_at: nil}} = Tay.get_schedule("audit%2Freport", name: @name)
  end

  for component <- [:coordinator, :executor, :http] do
    @component component
    test "#{component} loss fails closed and explicit restart restores current schedules", %{
      path: path,
      socket: socket
    } do
      options = http_options(@component)
      {root, engine, server} = start(path, socket, options)

      fields = %{
        "declaration_id" => "survives-gateway-failure",
        "task" => "audit.task",
        "every" => %{"hours" => 1},
        "delay" => 3600
      }

      assert {:ok, _} = Server.register_schedule(server, fields)

      pid =
        case @component do
          :executor ->
            server

          :coordinator ->
            :sys.get_state(server).schedule_coordinator

          :http ->
            gateways =
              Tay.Execution.Supervisor.components(:sys.get_state(engine).runtime).gateways

            Enum.find_value(DynamicSupervisor.which_children(gateways), fn
              {_, pid, _, [Tay.HTTP.Listener]} -> pid
              _ -> nil
            end)
        end

      Process.exit(pid, :kill)
      assert EngineHelpers.eventually(fn -> Tay.status(name: @name).state == :failed end)
      assert :ok = Tay.restart(name: @name, force: true)
      assert Tay.status(name: @name).state == :ready
      new_server = :sys.get_state(EngineHelpers.engine(root)).executor_server
      coordinator = :sys.get_state(new_server).schedule_coordinator
      assert Process.alive?(coordinator)
      assert Map.has_key?(:sys.get_state(coordinator).schedules, fields["declaration_id"])
      assert {:ok, _} = Server.register_schedule(new_server, fields)
      assert_http_server_rebound(options)
    end
  end
end
