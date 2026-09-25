defmodule Tay.Executor.ServerSocketTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Tay.Executor.Server

  setup do
    Process.flag(:trap_exit, true)
    root = Path.join(System.tmp_dir!(), "tay-server-socket-#{System.unique_integer([:positive])}")
    socket = Path.join(root, "tay.sock")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, socket: socket}
  end

  defp options(socket, private_directory \\ true) do
    %{
      engine: self(),
      engine_name: __MODULE__,
      socket_path: socket,
      socket_mode: 0o600,
      private_directory: private_directory,
      max_frame_bytes: 1_048_576,
      max_connections: 2,
      max_tasks_per_connection: 4,
      result_bytes: 65_536,
      error_bytes: 8_192,
      max_results: 2
    }
  end

  defp await_socket(socket, tries \\ 100)
  defp await_socket(_socket, 0), do: flunk("socket was not created")

  defp await_socket(socket, tries) do
    case File.lstat(socket) do
      {:ok, stat} ->
        stat

      _ ->
        Process.sleep(5)
        await_socket(socket, tries - 1)
    end
  end

  test "automatic directory creation is private and listener socket is 0600", %{
    root: root,
    socket: socket
  } do
    assert {:ok, server} = Server.start_link(options(socket))
    assert_receive {:executor_server_ready, ^server}

    _socket_stat = await_socket(socket)
    assert {:ok, directory} = File.stat(root)
    assert (directory.mode &&& 0o777) == 0o700
    assert {:ok, socket_stat} = File.stat(socket)
    assert (socket_stat.mode &&& 0o777) == 0o600

    GenServer.stop(server)
    assert {:error, :enoent} = File.lstat(socket)
  end

  test "a stale socket is reclaimed after an unorderly listener death", %{
    root: root,
    socket: socket
  } do
    assert {:ok, server} = Server.start_link(options(socket))
    assert_receive {:executor_server_ready, ^server}
    _ = await_socket(socket)
    Process.unlink(server)
    Process.exit(server, :kill)
    assert await_socket(socket)

    assert {:ok, replacement} = Server.start_link(options(socket))
    assert_receive {:executor_server_ready, ^replacement}
    assert await_socket(socket)
    GenServer.stop(replacement)
    assert {:ok, _} = File.stat(root)
  end

  test "a live listener socket is never reclaimed", %{socket: socket} do
    assert {:ok, server} = Server.start_link(options(socket))
    assert_receive {:executor_server_ready, ^server}
    _ = await_socket(socket)

    assert {:error, :socket_path_in_use} = Server.start_link(options(socket))
    assert Process.alive?(server)

    GenServer.stop(server)
  end

  test "a regular file is never overwritten at the configured socket path", %{
    root: root,
    socket: socket
  } do
    File.mkdir_p!(root)
    File.write!(socket, "do not replace")

    assert {:error, :socket_path_exists} = Server.start_link(options(socket, false))
    assert File.read!(socket) == "do not replace"
  end

  test "redeclaring the same stable schedule preserves its timer", %{socket: socket} do
    assert {:ok, server} = Server.start_link(options(socket))
    assert_receive {:executor_server_ready, ^server}

    fields = %{
      "declaration_id" => "stable-schedule",
      "task" => "media.cleanup-orphans.v1",
      "args" => %{},
      "every" => %{"hours" => 24},
      "delay" => 60,
      "options" => %{"queue" => "default"}
    }

    assert {:ok, first} = GenServer.call(server, {:put_schedule, fields})
    first_entry = :sys.get_state(server).schedules["stable-schedule"]
    assert {:ok, second} = GenServer.call(server, {:put_schedule, fields})
    second_entry = :sys.get_state(server).schedules["stable-schedule"]

    assert second == first
    assert second_entry.timer == first_entry.timer
    assert second_entry.schedule.next_at == first_entry.schedule.next_at

    changed = put_in(fields, ["every"], %{"hours" => 12})
    assert {:ok, _} = GenServer.call(server, {:put_schedule, changed})
    changed_entry = :sys.get_state(server).schedules["stable-schedule"]
    refute changed_entry.timer == first_entry.timer
    assert changed_entry.schedule.expression == 12 * 60 * 60 * 1_000

    GenServer.stop(server)
  end

  test "a due occurrence remains pending when durable admission is unavailable", %{
    socket: socket
  } do
    assert {:ok, server} = Server.start_link(options(socket))
    assert_receive {:executor_server_ready, ^server}

    fields = %{
      "declaration_id" => "retrying-schedule",
      "task" => "media.cleanup-orphans.v1",
      "args" => %{},
      "every" => %{"seconds" => 30},
      "options" => %{"queue" => "default"}
    }

    assert {:ok, first} = GenServer.call(server, {:put_schedule, fields})
    Process.sleep(50)
    entry = :sys.get_state(server).schedules["retrying-schedule"]

    assert entry.schedule.next_at == first["next_at"]
    assert is_reference(entry.timer)
    GenServer.stop(server)
  end

  test "invalid occurrence options reject the declaration", %{socket: socket} do
    assert {:ok, server} = Server.start_link(options(socket))
    assert_receive {:executor_server_ready, ^server}

    assert {:error, "invalid_schedule"} =
             GenServer.call(server, {
               :put_schedule,
               %{
                 "declaration_id" => "invalid-schedule",
                 "task" => "media.cleanup-orphans.v1",
                 "args" => %{},
                 "every" => %{"seconds" => 30},
                 "options" => %{"unknown" => true}
               }
             })

    GenServer.stop(server)
  end
end
