defmodule Tay.Executor.Server do
  @moduledoc false
  use GenServer
  alias Tay.Executor.{Connection, Protocol, Registry}
  alias Tay.Executor.Transport.Unix
  alias Tay.HTTP.WorkerSession
  alias Tay.Schedule.Coordinator

  @call_timeout 5_000
  @request_timeout 30_000
  @max_pending_requests 64

  # Executor sessions are deliberately children of an execution generation. Jobs are
  # durable, but socket handles, HTTP worker sessions and capacity reservations are
  # not: a restarted Tay starts with no executors until clients reconnect.
  def child_spec(options) do
    %{
      id: {__MODULE__, Map.fetch!(options, :socket_path)},
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def available_tasks(server), do: GenServer.call(server, :available_tasks, @call_timeout)

  def reserve(server, task), do: reserve(server, task, :all)

  def reserve(server, task, queue),
    do: GenServer.call(server, {:reserve, task, queue}, @call_timeout)

  def dispatch(server, reservation, job),
    do: GenServer.call(server, {:dispatch, reservation, job}, @call_timeout)

  def release(server, reservation),
    do: GenServer.call(server, {:release, reservation}, @call_timeout)

  def cancel(server, reservation),
    do: GenServer.call(server, {:cancel, reservation}, @call_timeout)

  def register_http_worker(server, runtime_id, tasks, capacity, queue),
    do:
      GenServer.call(
        server,
        {:register_http_worker, runtime_id, tasks, capacity, queue},
        @call_timeout
      )

  def http_worker(server, token), do: GenServer.call(server, {:http_worker, token}, @call_timeout)

  def hello(server, connection, session),
    do: GenServer.call(server, {:hello, connection, session}, @call_timeout)

  def register_tasks(server, connection, tasks),
    do: GenServer.call(server, {:register_tasks, connection, tasks}, @call_timeout)

  def unregister_tasks(server, connection, tasks),
    do: GenServer.call(server, {:unregister_tasks, connection, tasks}, @call_timeout)

  def started(server, connection, reservation, execution),
    do: GenServer.call(server, {:started, connection, reservation, execution}, @call_timeout)

  def complete(server, connection, reservation, execution, outcome),
    do:
      GenServer.call(
        server,
        {:complete, connection, reservation, execution, outcome},
        @call_timeout
      )

  def register_schedule(server, fields) do
    with {:ok, coordinator} <- GenServer.call(server, :schedule_coordinator, @call_timeout),
         do: Coordinator.register(coordinator, fields)
  end

  def cancel_schedule(server, id) do
    with {:ok, coordinator} <- GenServer.call(server, :schedule_coordinator, @call_timeout),
         do: Coordinator.cancel(coordinator, id)
  end

  def disconnected(server, connection), do: GenServer.cast(server, {:disconnected, connection})

  @impl true
  def init(options) do
    with {:ok, config} <- config(options),
         {:ok, coordinator, owns_coordinator} <- schedule_coordinator(config),
         {:ok, listener, acceptor, acceptor_monitor} <-
           Unix.open(config.socket_path, config.socket_mode, config.private_directory, self()) do
      state =
        Map.merge(
          Map.merge(Map.delete(config, :schedules), %{
            schedule_coordinator: coordinator,
            owns_coordinator: owns_coordinator
          }),
          %{
            listener: listener,
            acceptor: acceptor,
            acceptor_monitor: acceptor_monitor,
            http_workers: %{},
            connections: %{},
            monitors: %{},
            reservations: %{}
          }
        )

      send(config.engine, {:executor_server_ready, self()})
      {:ok, state, {:continue, :release_startup_heap}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:release_startup_heap, state) do
    :erlang.garbage_collect()
    {:noreply, state}
  end

  @impl true
  def handle_info({:executor_accepted, socket}, s) do
    if map_size(s.connections) >= s.max_connections do
      _ = :gen_tcp.close(socket)
      {:noreply, s}
    else
      options = %{
        socket: socket,
        server: self(),
        max_frame_bytes: s.max_frame_bytes,
        max_tasks: s.max_tasks_per_connection,
        request_timeout: @request_timeout,
        max_pending_requests: @max_pending_requests,
        result_bytes: s.result_bytes,
        error_bytes: s.error_bytes,
        engine_name: s.engine_name,
        schedule_coordinator: s.schedule_coordinator
      }

      case Connection.start_link(options) do
        {:ok, connection} ->
          :ok = :gen_tcp.controlling_process(socket, connection)
          send(connection, :socket_ready)
          monitor = Process.monitor(connection)

          state = %{
            s
            | connections:
                Map.put(s.connections, connection, %{
                  mode: nil,
                  runtime_id: nil,
                  capacity: 0,
                  tasks: MapSet.new(),
                  reservations: MapSet.new()
                }),
              monitors: Map.put(s.monitors, monitor, connection)
          }

          {:noreply, state}

        _ ->
          _ = :gen_tcp.close(socket)
          {:noreply, s}
      end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    case Map.pop(s.monitors, ref) do
      {nil, _} ->
        if ref == s.acceptor_monitor, do: {:stop, :acceptor_lost, s}, else: {:noreply, s}

      {connection, monitors} ->
        {:noreply, drop_connection(%{s | monitors: monitors}, connection)}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def handle_call(:available_tasks, _from, s),
    do: {:reply, Registry.capabilities(s.connections), s}

  def handle_call(:schedule_coordinator, _from, s),
    do: {:reply, {:ok, s.schedule_coordinator}, s}

  def handle_call({:put_schedule, fields}, from, s) do
    reply_async(from, fn -> Coordinator.register(s.schedule_coordinator, fields) end)
    {:noreply, s}
  end

  def handle_call({:cancel_schedule, id}, from, s) do
    reply_async(from, fn -> Coordinator.cancel(s.schedule_coordinator, id) end)
    {:noreply, s}
  end

  def handle_call({:register_http_worker, runtime_id, tasks, capacity, queue}, _from, s) do
    valid =
      Protocol.identifier?(runtime_id) and
        Registry.valid_tasks?(tasks, s.max_tasks_per_connection) and
        tasks != [] and is_integer(capacity) and capacity in 1..256 and
        Protocol.task_key?(queue) and map_size(s.connections) < s.max_connections

    if valid do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      {:ok, worker} = WorkerSession.start(capacity, self())
      monitor = Process.monitor(worker)

      entry = %{
        mode: "worker",
        runtime_id: runtime_id,
        capacity: capacity,
        tasks: MapSet.new(tasks),
        reservations: MapSet.new(),
        queue: queue,
        token: token
      }

      state = %{
        s
        | connections: Map.put(s.connections, worker, entry),
          monitors: Map.put(s.monitors, monitor, worker),
          http_workers: Map.put(s.http_workers, token, worker)
      }

      notify_capacity(state)
      {:reply, {:ok, token}, state}
    else
      {:reply, {:error, "invalid_worker"}, s}
    end
  end

  def handle_call({:http_worker, token}, _from, s) do
    case Map.fetch(s.http_workers, token) do
      {:ok, pid} -> {:reply, {:ok, pid, s.connections[pid].queue}, s}
      :error -> {:reply, {:error, "unknown_worker"}, s}
    end
  end

  def handle_call({:hello, connection, session}, _from, s) do
    case Map.fetch(s.connections, connection) do
      {:ok, %{mode: nil} = entry} ->
        case Registry.valid_session?(session) do
          true -> {:reply, :ok, put_connection(s, connection, Map.merge(entry, session))}
          false -> {:reply, {:error, "invalid_hello"}, s}
        end

      {:ok, _} ->
        {:reply, {:error, "already_hello"}, s}

      :error ->
        {:reply, {:error, "connection_closed"}, s}
    end
  end

  def handle_call({:register_tasks, connection, tasks}, _from, s) do
    with {:ok, entry} <- Registry.executor(s.connections, connection),
         true <-
           Registry.valid_tasks?(tasks, s.max_tasks_per_connection) || {:error, "invalid_tasks"} do
      state =
        put_connection(s, connection, %{
          entry
          | tasks: MapSet.union(entry.tasks, MapSet.new(tasks))
        })

      notify_capacity(state)
      {:reply, :ok, state}
    else
      {:error, code} -> {:reply, {:error, code}, s}
    end
  end

  def handle_call({:unregister_tasks, connection, tasks}, _from, s) do
    with {:ok, entry} <- Registry.executor(s.connections, connection),
         true <-
           Registry.valid_tasks?(tasks, s.max_tasks_per_connection) || {:error, "invalid_tasks"} do
      state =
        put_connection(s, connection, %{
          entry
          | tasks: MapSet.difference(entry.tasks, MapSet.new(tasks))
        })

      notify_capacity(state)
      {:reply, :ok, state}
    else
      {:error, code} -> {:reply, {:error, code}, s}
    end
  end

  def handle_call({:reserve, task, queue}, _from, s) do
    case Registry.choose(s.connections, task, queue) do
      nil ->
        {:reply, {:error, :unavailable}, s}

      connection ->
        reservation = reservation_id()
        entry = s.connections[connection]
        next_entry = %{entry | reservations: MapSet.put(entry.reservations, reservation)}

        state =
          s
          |> put_connection(connection, next_entry)
          |> Map.put(
            :reservations,
            Map.put(s.reservations, reservation, %{
              connection: connection,
              task: task,
              status: :reserved,
              execution_id: nil,
              job_id: nil
            })
          )

        notify_capacity(state)
        {:reply, {:ok, reservation}, state}
    end
  end

  def handle_call({:dispatch, reservation, job}, _from, s) do
    with {:ok, %{status: :reserved, connection: connection, task: task} = value} <-
           reservation(s, reservation),
         {:ok, _entry} <- connection(s, connection),
         true <-
           (Protocol.task_key?(task) and job.worker_key == task) || {:error, :invalid_dispatch},
         true <- (is_binary(job.id) and is_map(job.args)) || {:error, :invalid_dispatch} do
      execution = reservation_id()

      message = %{
        "version" => Protocol.version(),
        "type" => "execute",
        "request_id" => execution,
        "reservation_id" => reservation,
        "execution_id" => execution,
        "job_id" => job.id,
        "task" => task,
        "args" => job.args,
        "timeout_ms" => job.timeout_ms
      }

      reservation_value = %{
        value
        | status: :inflight,
          execution_id: execution,
          job_id: job.id
      }

      # Delivery is ordered in the connection mailbox but must not wait for
      # that GenServer. It can be processing a completion which synchronously
      # asks this server to validate the same connection. A send failure stops
      # the monitored connection; drop_connection/2 then reports every active
      # reservation as lost so the durable execution can be retried.
      :ok = Connection.deliver(connection, message)

      {:reply, :ok, %{s | reservations: Map.put(s.reservations, reservation, reservation_value)}}
    else
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:started, connection, reservation, execution}, _from, s) do
    case Map.get(s.reservations, reservation) do
      %{connection: ^connection, status: status, execution_id: ^execution}
      when status in [:inflight, :started] ->
        {:reply, :ok, put_in(s.reservations[reservation].status, :started)}

      _ ->
        {:reply, {:error, "unknown_execution"}, s}
    end
  end

  def handle_call({:complete, connection, reservation, execution, outcome}, _from, s) do
    case Map.get(s.reservations, reservation) do
      %{connection: ^connection, status: status, execution_id: ^execution}
      when status in [:inflight, :started] ->
        state = put_in(s.reservations[reservation].status, :completed)
        send(s.engine, {:executor_completion, self(), reservation, outcome})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, "unknown_execution"}, s}
    end
  end

  def handle_call({:release, reservation}, _from, s),
    do: {:reply, :ok, release_reservation(s, reservation)}

  def handle_call({:cancel, reservation}, _from, s) do
    state =
      case Map.get(s.reservations, reservation) do
        %{connection: connection, execution_id: execution} when is_binary(execution) ->
          _ =
            Connection.deliver(connection, %{
              "version" => Protocol.version(),
              "type" => "cancel_execution",
              "request_id" => reservation_id(),
              "reservation_id" => reservation,
              "execution_id" => execution
            })

          s

        _ ->
          s
      end

    {:reply, :ok, state}
  end

  def handle_call(_request, _from, s), do: {:reply, {:error, :invalid_request}, s}

  @impl true
  def handle_cast({:disconnected, connection}, s), do: {:noreply, drop_connection(s, connection)}

  @impl true
  def terminate(_reason, s) do
    Enum.each(Map.keys(s.connections), &Connection.close/1)

    if s.owns_coordinator and Process.alive?(s.schedule_coordinator),
      do: GenServer.stop(s.schedule_coordinator)

    Unix.close(s.listener, s.acceptor, s.socket_path)
  end

  defp config(options) when is_map(options) do
    with true <- is_pid(options.engine) || {:error, :invalid_engine},
         true <- is_atom(options.engine_name) || {:error, :invalid_engine_name},
         true <-
           (is_nil(Map.get(options, :schedule_coordinator)) or
              is_pid(options.schedule_coordinator)) || {:error, :invalid_schedule_coordinator},
         true <- is_map(Map.get(options, :schedules, %{})) || {:error, :invalid_durable_state},
         true <-
           (is_nil(options.socket_path) or Unix.valid_path?(options.socket_path)) ||
             {:error, :invalid_socket_path},
         true <- options.socket_mode in [0o600, 0o660] || {:error, :invalid_socket_mode},
         true <- is_boolean(options.private_directory) || {:error, :invalid_socket_directory_mode},
         true <-
           valid_positive?(options.max_frame_bytes, 16_777_216) || {:error, :invalid_frame_limit},
         true <-
           valid_positive?(options.max_connections, 4_096) || {:error, :invalid_connection_limit},
         true <-
           valid_positive?(options.max_tasks_per_connection, 4_096) ||
             {:error, :invalid_task_limit},
         true <-
           valid_positive?(options.result_bytes, options.max_frame_bytes) ||
             {:error, :invalid_result_limit},
         true <-
           valid_positive?(options.error_bytes, options.max_frame_bytes) ||
             {:error, :invalid_error_limit} do
      {:ok,
       options
       |> Map.put_new(:schedule_coordinator, nil)
       |> Map.put_new(:schedules, %{})
       |> Map.take([
         :engine,
         :engine_name,
         :schedule_coordinator,
         :schedules,
         :socket_path,
         :socket_mode,
         :private_directory,
         :max_frame_bytes,
         :max_connections,
         :max_tasks_per_connection,
         :result_bytes,
         :error_bytes
       ])}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_server_options}
    end
  end

  defp config(_), do: {:error, :invalid_server_options}
  defp valid_positive?(value, maximum), do: is_integer(value) and value in 1..maximum

  defp schedule_coordinator(%{schedule_coordinator: coordinator}) when is_pid(coordinator),
    do: {:ok, coordinator, false}

  defp schedule_coordinator(config) do
    case Coordinator.start_link(%{
           core: {Tay.Core.Local, config.engine_name},
           schedules: config.schedules
         }) do
      {:ok, coordinator} -> {:ok, coordinator, true}
      {:error, _} = error -> error
    end
  end

  defp reply_async(from, function) do
    Task.start(fn -> GenServer.reply(from, function.()) end)
    :ok
  end

  defp reservation(s, id) do
    case Map.fetch(s.reservations, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :unknown_reservation}
    end
  end

  defp connection(s, pid) do
    case Map.fetch(s.connections, pid) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :connection_closed}
    end
  end

  defp put_connection(s, connection, entry),
    do: %{s | connections: Map.put(s.connections, connection, entry)}

  defp release_reservation(s, reservation) do
    case Map.pop(s.reservations, reservation) do
      {nil, _} ->
        s

      {%{connection: connection}, reservations} ->
        state = %{s | reservations: reservations}

        state =
          update_in(state.connections[connection], fn
            nil -> nil
            entry -> %{entry | reservations: MapSet.delete(entry.reservations, reservation)}
          end)

        notify_capacity(state)
        state
    end
  end

  defp drop_connection(s, connection) do
    case Map.pop(s.connections, connection) do
      {nil, _} ->
        s

      {entry, connections} ->
        Enum.each(entry.reservations, fn reservation ->
          case Map.get(s.reservations, reservation) do
            %{status: status} when status in [:inflight, :started, :completed] ->
              send(s.engine, {:executor_completion, self(), reservation, :lost})

            _ ->
              :ok
          end
        end)

        state = %{
          s
          | connections: connections,
            reservations: Map.drop(s.reservations, MapSet.to_list(entry.reservations)),
            http_workers:
              if(Map.has_key?(entry, :token),
                do: Map.delete(s.http_workers, entry.token),
                else: s.http_workers
              )
        }

        notify_capacity(state)
        state
    end
  end

  defp notify_capacity(s), do: send(s.engine, {:executor_capacity_changed, self()})

  defp reservation_id do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end
end
