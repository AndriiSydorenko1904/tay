defmodule Tay.Executor.ScheduleConcurrencyTest do
  use ExUnit.Case, async: false

  alias Tay.Executor.Server
  alias Tay.Test.{EngineHelpers, ExecutionHelpers, NativeHelpers}

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    ExecutionHelpers.install()
    path = NativeHelpers.path()
    socket = Path.join(Path.dirname(path), "schedule-#{System.unique_integer([:positive])}.sock")
    ExecutionHelpers.initialize(path)

    on_exit(fn ->
      File.rm(socket)
      File.rm_rf!(path)
    end)

    %{path: path, socket: socket}
  end

  test "durable schedule operations remain ordered without blocking capacity polling", %{
    path: path,
    socket: socket
  } do
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> true end)

    hook = fn
      :pre_reply ->
        if Agent.get(gate, & &1) do
          token = make_ref()
          send(parent, {:durable_reply_blocked, self(), token})

          receive do
            {:release_durable_reply, ^token} -> :ok
          end
        end

      _ ->
        :ok
    end

    assert {:ok, root} =
             ExecutionHelpers.start(path, @name,
               workers: %{},
               executor_socket: socket,
               executor_max_connections: 2,
               test_hook: hook
             )

    on_exit(fn ->
      try do
        EngineHelpers.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    engine = EngineHelpers.engine(root)

    server =
      ExecutionHelpers.eventually(fn ->
        case :sys.get_state(engine).executor_server do
          pid when is_pid(pid) -> pid
          _ -> false
        end
      end)

    fields = %{
      "declaration_id" => "ordered-schedule",
      "task" => "executor.schedule.v1",
      "args" => %{},
      "every" => %{"hours" => 24},
      "delay" => 60,
      "options" => %{"queue" => "default"}
    }

    registration = Task.async(fn -> Server.register_schedule(server, fields) end)
    assert_receive {:durable_reply_blocked, durable_engine, register_token}, 1_000
    refute Task.yield(registration, 0)

    duplicate = Task.async(fn -> Server.register_schedule(server, fields) end)
    # Establish admission order before starting an independent caller. Task
    # creation alone does not order messages from different processes.
    assert ExecutionHelpers.eventually(fn ->
             :ets.match_object(@name, {{:schedule, :_}, :_, duplicate.pid, :submitted, :_}) != []
           end)

    cancellation =
      Task.async(fn -> Server.cancel_schedule(server, "ordered-schedule") end)

    started = System.monotonic_time(:millisecond)
    assert [] == Server.available_tasks(server)
    assert System.monotonic_time(:millisecond) - started < 500
    refute Task.yield(duplicate, 0)
    refute Task.yield(cancellation, 0)

    send(durable_engine, {:release_durable_reply, register_token})
    assert {:ok, registered} = Task.await(registration, 1_000)

    assert_receive {:durable_reply_blocked, ^durable_engine, duplicate_token}, 1_000
    refute Task.yield(duplicate, 0)
    assert [] == Server.available_tasks(server)
    send(durable_engine, {:release_durable_reply, duplicate_token})
    assert {:ok, ^registered} = Task.await(duplicate, 1_000)

    assert_receive {:durable_reply_blocked, ^durable_engine, cancel_token}, 1_000
    refute Task.yield(cancellation, 0)
    assert [] == Server.available_tasks(server)

    send(durable_engine, {:release_durable_reply, cancel_token})
    assert {:ok, cancelled} = Task.await(cancellation, 1_000)
    assert cancelled["revision"] == registered["revision"] + 1
    assert is_integer(cancelled["cancelled_at"])

    Agent.update(gate, fn _ -> false end)

    assert {:ok, [%{id: "ordered-schedule", cancelled_at: cancelled_at}]} =
             Tay.schedules(name: @name)

    assert is_integer(cancelled_at)
  end

  test "redeclaring after Elixir cancellation reads durable state instead of the cached entry", %{
    path: path,
    socket: socket
  } do
    assert {:ok, root} = EngineHelpers.start(path, @name)
    stop_on_exit(root)
    assert {:ok, server} = Server.start_link(server_options(socket, @name))
    stop_on_exit(server)
    assert_receive {:executor_server_ready, ^server}

    fields = %{
      "declaration_id" => "elixir-cancellation",
      "task" => "executor.schedule.v1",
      "every" => %{"hours" => 24},
      "delay" => 60
    }

    assert {:ok, registered} = Server.register_schedule(server, fields)
    assert {:ok, cancelled} = Tay.cancel_schedule("elixir-cancellation", name: @name)
    assert cancelled.revision == registered["revision"] + 1
    assert is_integer(cancelled.cancelled_at)

    assert {:ok, redeclared} = Server.register_schedule(server, fields)
    assert redeclared["revision"] == cancelled.revision + 1
    assert redeclared["cancelled_at"] == nil

    assert {:ok, stored} = Tay.get_schedule("elixir-cancellation", name: @name)
    assert stored.revision == redeclared["revision"]
    assert stored.cancelled_at == nil
    assert {:ok, ^redeclared} = Server.register_schedule(server, fields)

    GenServer.stop(server)
    EngineHelpers.stop(root)
    assert {:ok, root} = EngineHelpers.restart(path, @name)
    stop_on_exit(root)
    assert {:ok, recovered} = Tay.get_schedule("elixir-cancellation", name: @name)
    assert recovered.revision == stored.revision
    assert recovered.cancelled_at == nil
  end

  test "an unknown cancellation outcome is reported and never retried", %{
    path: path,
    socket: socket
  } do
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> false end)

    hook = fn
      :pre_reply ->
        if Agent.get(gate, & &1) do
          send(parent, {:cancellation_committed, self()})
          Process.sleep(:infinity)
        end

      _ ->
        :ok
    end

    assert {:ok, root} = EngineHelpers.start(path, @name, test_hook: hook)
    engine = EngineHelpers.engine(root)
    assert {:ok, server} = Server.start_link(server_options(socket, @name))
    assert_receive {:executor_server_ready, ^server}

    fields = %{
      "declaration_id" => "unknown-cancellation",
      "task" => "executor.schedule.v1",
      "args" => %{},
      "every" => %{"hours" => 24},
      "delay" => 60,
      "options" => %{"queue" => "default"}
    }

    assert {:ok, _registered} = Server.register_schedule(server, fields)
    Agent.update(gate, fn _ -> true end)

    cancellation =
      Task.async(fn ->
        Tay.Protocol.Service.handle(%{engine: @name, executor: server}, %{
          "type" => "cancel_schedule",
          "schedule_id" => "unknown-cancellation"
        })
      end)

    assert_receive {:cancellation_committed, ^engine}, 1_000
    Process.exit(engine, :kill)

    assert {:error, "unknown_outcome", %{"reason" => _}} = Task.await(cancellation, 6_000)

    assert ExecutionHelpers.eventually(fn ->
             server_state = :sys.get_state(server)
             state = :sys.get_state(server_state.schedule_coordinator)

             state.schedules == %{} and is_nil(state.operation) and
               :queue.is_empty(state.operations)
           end)

    GenServer.stop(server)
  end

  defp stop_on_exit(pid) do
    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp server_options(socket, engine_name) do
    %{
      engine: self(),
      engine_name: engine_name,
      socket_path: socket,
      socket_mode: 0o600,
      private_directory: true,
      max_frame_bytes: 1_048_576,
      max_connections: 2,
      max_tasks_per_connection: 4,
      result_bytes: 65_536,
      error_bytes: 8_192,
      max_results: 16
    }
  end
end
