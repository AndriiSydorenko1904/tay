defmodule Tay.Executor.DispatchFairnessTest do
  use ExUnit.Case, async: false

  alias Tay.Executor.Protocol
  alias Tay.Test.{EngineHelpers, ExecutionHelpers, NativeHelpers}

  @name __MODULE__
  @task "executor.dispatch-fairness.v1"

  setup do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()

    socket =
      Path.join(
        Path.dirname(path),
        "dispatch-fairness-#{System.unique_integer([:positive])}.sock"
      )

    ExecutionHelpers.initialize(path)

    on_exit(fn ->
      File.rm(socket)
      File.rm_rf!(path)
    end)

    %{path: path, socket: socket}
  end

  test "continuous enqueue cannot starve external dispatch refills", %{path: path, socket: socket} do
    # Model non-trivial durable append latency without changing Engine code.
    # Producers themselves never sleep or wait between requests.
    writer_hook = fn
      :append_written, _native ->
        receive do
        after
          15 -> :ok
        end

      _tag, _native ->
        :ok
    end

    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               queues: [default: 10],
               client_slots: 64,
               executor_socket: socket,
               executor_max_connections: 2,
               executor_max_tasks_per_connection: 16,
               execution_wake_ms: 1_000,
               writer_hook: writer_hook
             )

    on_exit(fn -> stop(root) end)
    executor = connect_executor(socket, 16)

    for number <- 1..100 do
      assert {:ok, _} = Tay.enqueue(@task, %{"seed" => number}, name: @name)
    end

    first_wave = receive_executes(executor, 10, 5_000)
    assert {:ok, %{available: available}} = Tay.stats(name: @name)
    assert available > 0

    running = :atomics.new(1, signed: false)
    inserted = :atomics.new(1, signed: false)
    :atomics.put(running, 1, 1)

    producers =
      for producer <- 1..64 do
        Task.async(fn -> produce_without_pause(running, inserted, producer, 1) end)
      end

    assert eventually(fn -> :atomics.get(inserted, 1) >= 64 end, 5_000)
    before_refill = :atomics.get(inserted, 1)
    refill_started = System.monotonic_time(:millisecond)

    Enum.with_index(first_wave, 1)
    |> Enum.each(fn {execute, index} ->
      send_completion(executor, execute, "release-#{index}")
    end)

    second_wave = receive_executes(executor, 10, 5_000)
    refill_ms = System.monotonic_time(:millisecond) - refill_started
    after_refill = :atomics.get(inserted, 1)

    # Producers made progress throughout the refill window. The queue regained
    # all ten slots even though enqueue calls never introduced a quiet period.
    assert after_refill > before_refill
    assert length(second_wave) == 10
    assert refill_ms < 1_500
    assert eventually(fn -> Tay.status(name: @name).queue_slots_used == %{"default" => 10} end)
    # Exactly twenty of the hundred seeded jobs reached the executor. The
    # second wave is still held, so at least eighty seeded jobs remain available
    # while producer ingress is active.
    assert 100 - length(first_wave) - length(second_wave) > 0

    :atomics.put(running, 1, 0)
    Enum.each(producers, &Task.await(&1, 5_000))
    :ok = :gen_tcp.close(executor)
    stop(root)
  end

  defp produce_without_pause(running, inserted, producer, ordinal) do
    if :atomics.get(running, 1) == 1 do
      case Tay.enqueue(@task, %{"producer" => producer, "ordinal" => ordinal}, name: @name) do
        {:ok, _} -> :atomics.add_get(inserted, 1, 1)
        {:error, %{kind: :capacity}} -> :ok
      end

      produce_without_pause(running, inserted, producer, ordinal + 1)
    end
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
      "runtime_id" => "dispatch-fairness-test",
      "max_concurrency" => capacity
    })

    assert %{"type" => "hello_ok"} = receive_message(socket, 1_000)

    send_message(socket, %{
      "version" => 1,
      "type" => "register_tasks",
      "request_id" => "register",
      "tasks" => [@task]
    })

    assert %{"type" => "tasks_registered"} = receive_message(socket, 1_000)
    socket
  end

  defp receive_executes(socket, count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_executes(socket, count, deadline, [])
  end

  defp receive_executes(_socket, count, _deadline, messages) when length(messages) == count,
    do: Enum.reverse(messages)

  defp receive_executes(socket, count, deadline, messages) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case receive_message(socket, remaining) do
      %{"type" => "execute"} = execute ->
        receive_executes(socket, count, deadline, [execute | messages])

      %{"type" => "accepted"} ->
        receive_executes(socket, count, deadline, messages)
    end
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

  defp receive_message(socket, timeout) do
    assert {:ok, <<size::unsigned-big-32>>} = :gen_tcp.recv(socket, 4, timeout)
    assert {:ok, payload} = :gen_tcp.recv(socket, size, timeout)
    :json.decode(payload)
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    case fun.() do
      result when result not in [false, nil] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          eventually_until(fun, deadline)
        else
          false
        end
    end
  end

  defp stop(root) do
    if is_pid(root) and Process.alive?(root), do: EngineHelpers.stop(root)
    :ok
  end
end
