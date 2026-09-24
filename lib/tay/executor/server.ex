defmodule Tay.Executor.Server do
  @moduledoc false
  use GenServer
  import Bitwise

  alias Tay.Executor.{Connection, Protocol}
  alias Tay.Schedule

  @call_timeout 5_000
  @request_timeout 30_000
  @max_pending_requests 64

  # The listener is deliberately a child of an execution generation.  Jobs are
  # durable, but socket handles, registrations and capacity reservations are
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
  def reserve(server, task), do: GenServer.call(server, {:reserve, task}, @call_timeout)

  def dispatch(server, reservation, job),
    do: GenServer.call(server, {:dispatch, reservation, job}, @call_timeout)

  def release(server, reservation),
    do: GenServer.call(server, {:release, reservation}, @call_timeout)

  def cancel(server, reservation),
    do: GenServer.call(server, {:cancel, reservation}, @call_timeout)

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

  def request(server, connection, message),
    do: GenServer.cast(server, {:request, connection, message})

  def disconnected(server, connection), do: GenServer.cast(server, {:disconnected, connection})

  @impl true
  def init(options) do
    with {:ok, config} <- config(options),
         :ok <- prepare_socket(config.socket_path, config.private_directory),
         {:ok, listener} <- listen(config.socket_path),
         :ok <- File.chmod(config.socket_path, config.socket_mode) do
      server = self()
      # The acceptor owns the listening port after handoff. Linking it prevents
      # an orphaned socket/accept loop if this generation is killed before its
      # orderly terminate callback can remove the ephemeral socket path.
      acceptor = spawn_link(fn -> acceptor_wait(server, listener) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)
      send(acceptor, :accept)

      state =
        Map.merge(config, %{
          listener: listener,
          acceptor: acceptor,
          acceptor_monitor: Process.monitor(acceptor),
          connections: %{},
          monitors: %{},
          reservations: %{},
          schedules: %{},
          results: %{},
          result_order: :queue.new()
        })

      send(config.engine, {:executor_server_ready, self()})
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
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
        error_bytes: s.error_bytes
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

  def handle_info({:schedule_due, id, due}, s) do
    case Map.get(s.schedules, id) do
      %{schedule: %{next_at: ^due} = schedule, options: options} ->
        enqueue_schedule(s.engine_name, schedule, options)

        case Schedule.advance(schedule, due) do
          {:ok, advanced} ->
            entry = arm_schedule(advanced, options, System.system_time(:millisecond))
            {:noreply, %{s | schedules: Map.put(s.schedules, id, entry)}}

          {:error, _} ->
            {:noreply, drop_schedule(s, id)}
        end

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def handle_call(:available_tasks, _from, s), do: {:reply, capabilities(s), s}

  def handle_call({:result, job_id}, _from, s) when is_binary(job_id) do
    case Map.fetch(s.results, job_id) do
      {:ok, result} -> {:reply, {:ok, result}, s}
      :error -> {:reply, :missing, s}
    end
  end

  def handle_call({:hello, connection, session}, _from, s) do
    case Map.fetch(s.connections, connection) do
      {:ok, %{mode: nil} = entry} ->
        case valid_session?(session) do
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
    with {:ok, entry} <- executor_connection(s, connection),
         true <- valid_tasks?(tasks, s.max_tasks_per_connection) || {:error, "invalid_tasks"} do
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
    with {:ok, entry} <- executor_connection(s, connection),
         true <- valid_tasks?(tasks, s.max_tasks_per_connection) || {:error, "invalid_tasks"} do
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

  def handle_call({:put_schedule, fields}, _from, s) do
    id = Map.get(fields, "declaration_id") || schedule_id()
    now = System.system_time(:millisecond)

    case Schedule.new(id, fields, now) do
      {:ok, schedule} ->
        options = Map.get(fields, "options", %{})

        existing_entry = Map.get(s.schedules, id)

        if equivalent_schedule_entry?(existing_entry, schedule, options) do
          {:reply, {:ok, public_schedule(existing_entry.schedule)}, s}
        else
          state = drop_schedule(s, id)
          entry = arm_schedule(schedule, options, now)
          next = %{state | schedules: Map.put(state.schedules, id, entry)}
          {:reply, {:ok, public_schedule(schedule)}, next}
        end

      {:error, _} ->
        {:reply, {:error, "invalid_schedule"}, s}
    end
  end

  def handle_call({:cancel_schedule, id}, _from, s) do
    case Map.fetch(s.schedules, id) do
      {:ok, %{schedule: schedule}} ->
        cancelled = Schedule.cancel(schedule, System.system_time(:millisecond))
        {:reply, {:ok, public_schedule(cancelled)}, drop_schedule(s, id)}

      :error ->
        {:reply, {:error, "schedule_not_found"}, s}
    end
  end

  def handle_call({:reserve, task}, _from, s) do
    case choose_executor(s, task) do
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
      %{connection: ^connection, status: status, execution_id: ^execution} = value
      when status in [:inflight, :started] ->
        state = put_in(s.reservations[reservation].status, :completed)

        state =
          if match?({:success, _}, outcome),
            do: put_result(state, value.job_id, outcome),
            else: state

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

  def handle_cast({:request, connection, message}, s) do
    if Map.has_key?(s.connections, connection) do
      server = self()
      Task.start(fn -> reply_request(server, s.engine_name, connection, message) end)
    end

    {:noreply, s}
  end

  @impl true
  def terminate(_reason, s) do
    Enum.each(Map.keys(s.connections), &Connection.close/1)
    if is_port(s.listener), do: :gen_tcp.close(s.listener)

    if is_pid(s.acceptor) do
      Process.unlink(s.acceptor)
      Process.exit(s.acceptor, :shutdown)
    end

    remove_socket(s.socket_path)
    :ok
  end

  defp config(options) when is_map(options) do
    with true <- is_pid(options.engine) || {:error, :invalid_engine},
         true <- is_atom(options.engine_name) || {:error, :invalid_engine_name},
         true <- socket_path?(options.socket_path) || {:error, :invalid_socket_path},
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
             {:error, :invalid_error_limit},
         true <- valid_positive?(options.max_results, 100_000) || {:error, :invalid_result_count} do
      {:ok,
       Map.take(options, [
         :engine,
         :engine_name,
         :socket_path,
         :socket_mode,
         :private_directory,
         :max_frame_bytes,
         :max_connections,
         :max_tasks_per_connection,
         :result_bytes,
         :error_bytes,
         :max_results
       ])}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_server_options}
    end
  end

  defp config(_), do: {:error, :invalid_server_options}
  defp valid_positive?(value, maximum), do: is_integer(value) and value in 1..maximum

  defp socket_path?(path) when is_binary(path) do
    Path.type(path) == :absolute and String.valid?(path) and byte_size(path) in 1..100 and
      not String.contains?(path, <<0>>)
  end

  defp socket_path?(_), do: false

  defp prepare_socket(path, private_directory) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- protect_directory(Path.dirname(path), private_directory) do
      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, stat} ->
          if(is_socket?(stat),
            do: reclaim_stale_socket(path),
            else: {:error, :socket_path_exists}
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp protect_directory(_path, false), do: :ok
  defp protect_directory(path, true), do: File.chmod(path, 0o700)

  # A pathname socket can outlive an unorderly listener death, but it can also
  # name a healthy Tay instance. Probe it before unlinking: only an explicit
  # connection refusal is stale. Permission, protocol and transient failures
  # deliberately preserve the existing object rather than risking disruption.
  defp reclaim_stale_socket(path) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 100) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        {:error, :socket_path_in_use}

      {:error, :econnrefused} ->
        remove_if_socket(path)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:socket_path_unavailable, reason}}
    end
  end

  defp remove_if_socket(path) do
    case File.lstat(path) do
      {:ok, stat} -> if(is_socket?(stat), do: File.rm(path), else: {:error, :socket_path_exists})
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp listen(path) do
    :gen_tcp.listen(0, [
      :binary,
      active: false,
      packet: 0,
      ifaddr: {:local, String.to_charlist(path)}
    ])
  end

  defp acceptor_wait(server, listener) do
    receive do
      :accept -> acceptor_loop(server, listener)
    end
  end

  defp acceptor_loop(server, listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case :gen_tcp.controlling_process(socket, server) do
          :ok -> send(server, {:executor_accepted, socket})
          _ -> :gen_tcp.close(socket)
        end

        acceptor_loop(server, listener)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        send(server, :executor_accept_failed)
    end
  end

  defp valid_session?(%{mode: mode, runtime_id: id, capacity: capacity}) do
    mode in ["client", "embedded", "worker"] and Protocol.identifier?(id) and
      is_integer(capacity) and capacity in 0..65_535 and
      (mode == "client" or capacity > 0) and (mode != "client" or capacity == 0)
  end

  defp valid_session?(_), do: false

  defp executor_connection(s, connection) do
    case Map.get(s.connections, connection) do
      %{mode: mode} = entry when mode in ["embedded", "worker"] -> {:ok, entry}
      %{mode: "client"} -> {:error, "client_cannot_execute"}
      nil -> {:error, "connection_closed"}
      _ -> {:error, "hello_required"}
    end
  end

  defp valid_tasks?(tasks, maximum) do
    is_list(tasks) and length(tasks) <= maximum and Enum.all?(tasks, &Protocol.task_key?/1) and
      length(tasks) == length(Enum.uniq(tasks))
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

  defp capabilities(s) do
    s.connections
    |> Enum.filter(fn {_connection, entry} -> executor_available?(entry) end)
    |> Enum.flat_map(fn {_connection, entry} -> MapSet.to_list(entry.tasks) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp choose_executor(s, task) do
    if Protocol.task_key?(task) do
      s.connections
      |> Enum.filter(fn {_connection, entry} ->
        executor_available?(entry) and MapSet.member?(entry.tasks, task)
      end)
      |> Enum.min_by(
        fn {connection, entry} ->
          {MapSet.size(entry.reservations), entry.runtime_id, connection}
        end,
        fn -> nil end
      )
      |> case do
        nil -> nil
        {connection, _} -> connection
      end
    end
  end

  defp executor_available?(entry),
    do: entry.mode in ["embedded", "worker"] and MapSet.size(entry.reservations) < entry.capacity

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
            reservations: Map.drop(s.reservations, MapSet.to_list(entry.reservations))
        }

        notify_capacity(state)
        state
    end
  end

  defp put_result(s, nil, _outcome), do: s

  defp put_result(s, job_id, {:success, result}) do
    # Results are bounded by Connection before this point and count-bounded
    # here. Event-v1 persists completion, but intentionally has no result field,
    # so this is live-generation retention rather than an imaginary durable
    # result backend.
    if Map.has_key?(s.results, job_id) do
      %{s | results: Map.put(s.results, job_id, result)}
    else
      {results, order} = trim_results(s.results, s.result_order, s.max_results - 1)
      %{s | results: Map.put(results, job_id, result), result_order: :queue.in(job_id, order)}
    end
  end

  defp trim_results(results, order, limit) when map_size(results) <= limit, do: {results, order}

  defp trim_results(results, order, limit) do
    case :queue.out(order) do
      {{:value, job_id}, next_order} ->
        trim_results(Map.delete(results, job_id), next_order, limit)

      {:empty, _} ->
        {%{}, :queue.new()}
    end
  end

  defp notify_capacity(s), do: send(s.engine, {:executor_capacity_changed, self()})

  defp reservation_id do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end

  defp remove_socket(path) do
    case File.lstat(path) do
      {:ok, stat} -> if(is_socket?(stat), do: File.rm(path), else: :ok)
      _ -> :ok
    end
  end

  defp is_socket?(%{mode: mode}) when is_integer(mode), do: (mode &&& 0o170000) == 0o140000
  defp is_socket?(_), do: false

  defp reply_request(
         server,
         engine_name,
         connection,
         %{"type" => type, "request_id" => request_id} = message
       ) do
    result =
      case type do
        "enqueue" -> enqueue(engine_name, message)
        "status" -> status(engine_name, message)
        "cancel" -> cancel_job(engine_name, message)
        "result" -> result(server, engine_name, message)
        "schedule" -> schedule(server, message)
        "cancel_schedule" -> cancel_schedule(server, message)
        _ -> {:error, "unsupported_request"}
      end

    case result do
      {:ok, reply_type, fields} -> Connection.reply(connection, request_id, reply_type, fields)
      {:error, code} -> Connection.error(connection, request_id, code)
      {:error, code, fields} -> Connection.error(connection, request_id, code, fields)
    end
  catch
    :exit, _ -> Connection.error(connection, request_id, "unavailable")
    _, _ -> Connection.error(connection, request_id, "invalid_request")
  end

  defp reply_request(_, _, _, _), do: :ok

  defp enqueue(engine_name, %{"task" => task, "args" => args} = message) do
    with {:ok, options} <- enqueue_options(Map.get(message, "options", %{})),
         {:ok, job} <- Tay.enqueue(task, args, [name: engine_name] ++ options) do
      {:ok, "enqueued", %{"job_id" => job.id, "job" => public_job(job)}}
    else
      {:error, %Tay.Error{kind: :unknown_outcome}} ->
        {:error, "unknown_outcome"}

      {:error, %Tay.Error{kind: :capacity, reason: reason}} ->
        {:error, "capacity", %{"reason" => capacity_reason(reason)}}

      {:error, _} ->
        {:error, "invalid_enqueue"}

      _ ->
        {:error, "invalid_enqueue"}
    end
  end

  defp capacity_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp capacity_reason(_), do: "capacity_exhausted"

  defp status(engine_name, %{"job_id" => id}) do
    case Tay.get_job(id, name: engine_name) do
      {:ok, job} ->
        {:ok, "status", %{"job" => public_job(job), "status" => Atom.to_string(job.state)}}

      {:error, :not_found} ->
        {:error, "not_found"}

      _ ->
        {:error, "unavailable"}
    end
  end

  defp cancel_job(engine_name, %{"job_id" => id}) do
    case Tay.cancel(id, name: engine_name) do
      {:ok, job} ->
        {:ok, "cancelled", %{"job" => public_job(job), "status" => Atom.to_string(job.state)}}

      {:error, :not_found} ->
        {:error, "not_found"}

      {:error, _} ->
        {:error, "cancel_rejected"}
    end
  end

  defp result(server, engine_name, %{"job_id" => id}) do
    case Tay.get_job(id, name: engine_name) do
      {:ok, %{state: :completed}} ->
        case GenServer.call(server, {:result, id}, @call_timeout) do
          {:ok, value} -> {:ok, "result", %{"result" => value}}
          :missing -> {:ok, "result", %{"result" => nil}}
        end

      {:ok, %{state: :discarded}} ->
        {:error, "task_failed"}

      {:ok, _} ->
        {:error, "result_not_ready"}

      {:error, :not_found} ->
        {:error, "not_found"}

      _ ->
        {:error, "unavailable"}
    end
  end

  defp schedule(server, message) do
    fields = Map.drop(message, ["version", "type", "request_id"])

    case GenServer.call(server, {:put_schedule, fields}, @call_timeout) do
      {:ok, value} ->
        {:ok, "scheduled", %{"schedule_id" => value["id"], "schedule" => value}}

      {:error, code} ->
        {:error, code}
    end
  end

  defp cancel_schedule(server, %{"schedule_id" => id}) when is_binary(id) do
    case GenServer.call(server, {:cancel_schedule, id}, @call_timeout) do
      {:ok, value} ->
        {:ok, "schedule_cancelled", %{"schedule_id" => id, "schedule" => value}}

      {:error, code} ->
        {:error, code}
    end
  end

  defp cancel_schedule(_, _), do: {:error, "invalid_schedule_id"}

  defp arm_schedule(schedule, options, now) do
    delay = max(schedule.next_at - now, 0)
    timer = Process.send_after(self(), {:schedule_due, schedule.id, schedule.next_at}, delay)
    %{schedule: schedule, options: options, timer: timer}
  end

  defp equivalent_schedule_entry?(%{schedule: existing, options: options}, candidate, options),
    do: Schedule.equivalent?(existing, candidate)

  defp equivalent_schedule_entry?(_, _, _), do: false

  defp drop_schedule(s, id) do
    case Map.pop(s.schedules, id) do
      {nil, _} ->
        s

      {%{timer: timer}, schedules} ->
        Process.cancel_timer(timer)
        %{s | schedules: schedules}
    end
  end

  defp enqueue_schedule(engine_name, schedule, raw_options) do
    Task.start(fn ->
      with {:ok, options} <- enqueue_options(raw_options) do
        _ = Tay.enqueue(schedule.task, schedule.args, [name: engine_name] ++ options)
      end
    end)
  end

  defp public_schedule(schedule) do
    %{
      "id" => schedule.id,
      "task" => schedule.task,
      "kind" => Atom.to_string(schedule.kind),
      "timezone" => schedule.timezone,
      "overlap" => schedule.overlap,
      "catch_up" => schedule.catch_up,
      "next_at" => schedule.next_at,
      "last_at" => schedule.last_at,
      "cancelled_at" => schedule.cancelled_at
    }
  end

  defp schedule_id, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

  defp enqueue_options(options) when is_map(options) and not is_struct(options) do
    allowed = ~w(submission_id id delay delay_ms run_at retries timeout timeout_ms backoff queue)

    if Enum.all?(Map.keys(options), &(&1 in allowed)) do
      with {:ok, id} <- submission_id(options),
           {:ok, delay} <- delay(options),
           {:ok, scheduled} <- run_at(options),
           {:ok, retries} <- integer_option(options, "retries", 0, 65_534),
           {:ok, timeout} <- timeout(options),
           :ok <- backoff(options),
           {:ok, queue} <- queue(options) do
        values = [
          id: id,
          retries: retries,
          timeout_ms: timeout,
          queue: queue,
          delay_ms: delay,
          scheduled_at: scheduled
        ]

        {:ok, Enum.reject(values, fn {_key, value} -> is_nil(value) end)}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp enqueue_options(_), do: {:error, :invalid_options}

  defp submission_id(options) do
    case {Map.get(options, "id"), Map.get(options, "submission_id")} do
      {nil, nil} ->
        {:ok, nil}

      {id, nil} ->
        if(match?({:ok, _}, Tay.JobID.decode(id)), do: {:ok, id}, else: {:error, :invalid_id})

      {nil, key} when is_binary(key) ->
        if Protocol.identifier?(key) do
          digest = :crypto.hash(:sha256, "tay-submission-v1:" <> key) |> binary_part(0, 16)
          {:ok, Tay.JobID.encode(if(digest == <<0::128>>, do: <<0::120, 1>>, else: digest))}
        else
          {:error, :invalid_submission_id}
        end

      _ ->
        {:error, :invalid_submission_id}
    end
  end

  defp delay(options) do
    case {Map.get(options, "delay"), Map.get(options, "delay_ms")} do
      {nil, nil} ->
        {:ok, nil}

      {value, nil} when is_integer(value) and value >= 0 ->
        {:ok, value * 1_000}

      {value, nil} when is_float(value) and value >= 0 and value == value ->
        {:ok, round(value * 1_000)}

      {nil, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, :invalid_delay}
    end
  end

  defp run_at(options) do
    case {Map.get(options, "run_at"), Map.get(options, "delay"), Map.get(options, "delay_ms")} do
      {nil, _, _} ->
        {:ok, nil}

      {_value, delay, delay_ms} when not is_nil(delay) or not is_nil(delay_ms) ->
        {:error, :ambiguous_schedule}

      {value, _, _} when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, :invalid_run_at}
    end
  end

  defp integer_option(options, key, default, maximum) do
    case Map.get(options, key, default) do
      value when is_integer(value) and value >= 0 and value <= maximum -> {:ok, value}
      _ -> {:error, :invalid_option}
    end
  end

  defp timeout(options) do
    case {Map.get(options, "timeout"), Map.get(options, "timeout_ms")} do
      {nil, nil} -> {:ok, 30_000}
      {value, nil} when is_integer(value) and value in 1..86_400 -> {:ok, value * 1_000}
      {value, nil} when is_float(value) and value > 0 -> {:ok, round(value * 1_000)}
      {nil, value} when is_integer(value) and value in 1..86_400_000 -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp backoff(options) do
    case Map.get(options, "backoff", "exponential") do
      value when value in [nil, "exponential"] -> :ok
      _ -> {:error, :unsupported_backoff}
    end
  end

  defp queue(options) do
    case Map.get(options, "queue", "default") do
      value when is_binary(value) ->
        if Protocol.task_key?(value), do: {:ok, value}, else: {:error, :invalid_queue}

      _ ->
        {:error, :invalid_queue}
    end
  end

  defp public_job(job) do
    %{
      "id" => job.id,
      "task" => job.worker_key,
      "args" => job.args,
      "state" => Atom.to_string(job.state),
      "attempt" => job.attempt,
      "max_attempts" => job.max_attempts,
      "queue" => to_string(job.queue),
      "scheduled_at" => present_time(job.scheduled_at),
      "completed_at" => present_time(job.completed_at),
      "errors" => job.errors
    }
  end

  defp present_time(nil), do: nil
  defp present_time(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp present_time(value), do: value
end
