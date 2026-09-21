defmodule Tay.Executor.ConnectionConcurrencyTest do
  use ExUnit.Case, async: false

  alias Tay.Executor.{Protocol, Server}

  @task "executor.concurrent.v1"

  setup do
    Process.flag(:trap_exit, true)

    root =
      Path.join(
        System.tmp_dir!(),
        "tay-executor-concurrency-#{System.unique_integer([:positive])}"
      )

    socket_path = Path.join(root, "tay.sock")

    on_exit(fn -> File.rm_rf!(root) end)
    %{socket_path: socket_path}
  end

  test "completion can enter a capacity-2 connection while another job is dispatched", %{
    socket_path: socket_path
  } do
    {:ok, server} = start_server(socket_path, self())
    assert_receive {:executor_server_ready, ^server}
    socket = connect_executor(socket_path, 2)
    connection = only_connection(server)

    {:ok, first_reservation} = Server.reserve(server, @task)
    :ok = Server.dispatch(server, first_reservation, job("first"))
    first_execute = recv_type(socket, "execute")

    {:ok, second_reservation} = Server.reserve(server, @task)

    # Put the completion ahead of the second delivery in the connection's
    # mailbox. On the old implementation the delivery was a GenServer.call:
    # after resume, Connection called Server.complete while Server was waiting
    # for that delivery call, deterministically closing the circular wait.
    :ok = :sys.suspend(connection)
    send_completion(socket, first_execute, "complete-first")
    assert eventually(fn -> queued_tcp?(connection) end)

    dispatch = Task.async(fn -> Server.dispatch(server, second_reservation, job("second")) end)
    assert eventually(fn -> queued_delivery?(connection) end)
    :ok = :sys.resume(connection)

    assert :ok = Task.await(dispatch, 1_000)
    assert %{"type" => "accepted", "request_id" => "complete-first"} = recv_message(socket)
    assert %{"type" => "execute"} = second_execute = recv_message(socket)

    assert_receive {:executor_completion, ^server, ^first_reservation,
                    {:success, %{"ok" => true}}},
                   1_000

    :ok = Server.release(server, first_reservation)
    send_completion(socket, second_execute, "complete-second")
    assert %{"type" => "accepted", "request_id" => "complete-second"} = recv_message(socket)

    assert_receive {:executor_completion, ^server, ^second_reservation,
                    {:success, %{"ok" => true}}},
                   1_000

    :ok = Server.release(server, second_reservation)
    :ok = :gen_tcp.close(socket)
    GenServer.stop(server)
  end

  test "concurrent dispatch and completion make progress on one multi-capacity connection", %{
    socket_path: socket_path
  } do
    parent = self()
    engine = spawn_link(fn -> engine_loop(parent) end)
    {:ok, server} = start_server(socket_path, engine)
    assert_receive {:executor_server_ready, ^server}

    count = 200
    client = spawn_link(fn -> stress_client(parent, socket_path, 8, count) end)
    assert_receive {:executor_client_ready, ^client}

    results =
      1..count
      |> Task.async_stream(
        fn number ->
          reservation = reserve_until_available(server)
          Server.dispatch(server, reservation, job("stress-#{number}"))
        end,
        max_concurrency: 32,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert_receive {:executor_client_done, ^client, ^count, ^count}, 10_000
    assert_receive {:executor_completions, ^count}, 10_000

    GenServer.stop(server)
  end

  defp start_server(socket_path, engine) do
    Server.start_link(%{
      engine: engine,
      engine_name: __MODULE__,
      socket_path: socket_path,
      socket_mode: 0o600,
      private_directory: true,
      max_frame_bytes: 1_048_576,
      max_connections: 2,
      max_tasks_per_connection: 4,
      result_bytes: 65_536,
      error_bytes: 8_192,
      max_results: 256
    })
  end

  defp connect_executor(socket_path, capacity) do
    assert eventually(fn -> File.exists?(socket_path) end)

    assert {:ok, socket} =
             :gen_tcp.connect(
               {:local, String.to_charlist(socket_path)},
               0,
               [:binary, active: false],
               1_000
             )

    send_message(socket, %{
      "version" => 1,
      "type" => "hello",
      "request_id" => "hello",
      "mode" => "worker",
      "runtime_id" => "concurrency-test",
      "max_concurrency" => capacity
    })

    assert %{"type" => "hello_ok", "request_id" => "hello"} = recv_message(socket)

    send_message(socket, %{
      "version" => 1,
      "type" => "register_tasks",
      "request_id" => "register",
      "tasks" => [@task]
    })

    assert %{"type" => "tasks_registered", "request_id" => "register"} = recv_message(socket)
    socket
  end

  defp stress_client(parent, socket_path, capacity, expected) do
    socket = connect_executor(socket_path, capacity)
    send(parent, {:executor_client_ready, self()})
    stress_client_loop(parent, socket, expected, 0, 0)
  end

  defp stress_client_loop(parent, socket, expected, executions, acknowledgements)
       when executions == expected and acknowledgements == expected do
    send(parent, {:executor_client_done, self(), executions, acknowledgements})
    :gen_tcp.close(socket)
  end

  defp stress_client_loop(parent, socket, expected, executions, acknowledgements) do
    case recv_message(socket, 10_000) do
      %{"type" => "execute"} = execute ->
        send_completion(socket, execute, "completion-#{executions + 1}")
        stress_client_loop(parent, socket, expected, executions + 1, acknowledgements)

      %{"type" => "accepted"} ->
        stress_client_loop(parent, socket, expected, executions, acknowledgements + 1)
    end
  end

  defp engine_loop(parent, server \\ nil, completions \\ 0) do
    receive do
      {:executor_server_ready, server} ->
        send(parent, {:executor_server_ready, server})
        engine_loop(parent, server, completions)

      {:executor_completion, ^server, reservation, {:success, %{"ok" => true}}} ->
        :ok = Server.release(server, reservation)
        next = completions + 1
        send(parent, {:executor_completions, next})
        engine_loop(parent, server, next)

      _message ->
        engine_loop(parent, server, completions)
    end
  end

  defp reserve_until_available(server) do
    case Server.reserve(server, @task) do
      {:ok, reservation} ->
        reservation

      {:error, :unavailable} ->
        Process.sleep(1)
        reserve_until_available(server)
    end
  end

  defp job(id) do
    %{id: id, worker_key: @task, args: %{"number" => id}, timeout_ms: 30_000}
  end

  defp send_completion(socket, execute, request_id) do
    send_message(socket, %{
      "version" => 1,
      "type" => "succeeded",
      "request_id" => request_id,
      "reservation_id" => execute["reservation_id"],
      "execution_id" => execute["execution_id"],
      "result" => %{"ok" => true}
    })
  end

  defp send_message(socket, message) do
    assert {:ok, frame} = Protocol.frame(message)
    assert :ok = :gen_tcp.send(socket, frame)
  end

  defp recv_type(socket, type) do
    assert %{"type" => ^type} = message = recv_message(socket)
    message
  end

  defp recv_message(socket, timeout \\ 1_000) do
    assert {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(socket, 4, timeout)
    assert {:ok, payload} = :gen_tcp.recv(socket, size, timeout)
    :json.decode(payload)
  end

  defp only_connection(server) do
    assert eventually(fn -> map_size(:sys.get_state(server).connections) == 1 end)
    [connection] = Map.keys(:sys.get_state(server).connections)
    connection
  end

  defp queued_tcp?(connection) do
    {:messages, messages} = Process.info(connection, :messages)
    Enum.any?(messages, &match?({:tcp, _, _}, &1))
  end

  defp queued_delivery?(connection) do
    {:messages, messages} = Process.info(connection, :messages)

    Enum.any?(messages, fn
      {:"$gen_cast", {:deliver, _}} -> true
      {:"$gen_call", _, {:deliver, _}} -> true
      _ -> false
    end)
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
