defmodule Tay.Executor.Connection do
  @moduledoc false
  use GenServer

  alias Tay.Executor.{Protocol, Server}

  @send_timeout 5_000

  # Connections are deliberately not linked to the listener.  A malformed or
  # crashed local client must only lose its own capacity, not the Engine's UDS
  # listener or storage generation.
  def start_link(options), do: GenServer.start(__MODULE__, options)

  def deliver(connection, message),
    do: GenServer.cast(connection, {:deliver, message})

  def reply(connection, request_id, type, fields \\ %{}) do
    try do
      GenServer.call(connection, {:reply, request_id, type, fields}, @send_timeout)
    catch
      :exit, _ -> {:error, :connection_closed}
    end
  end

  def error(connection, request_id, code) do
    try do
      GenServer.call(connection, {:error, request_id, code}, @send_timeout)
    catch
      :exit, _ -> {:error, :connection_closed}
    end
  end

  def close(connection), do: GenServer.cast(connection, :close)

  @impl true
  def init(options) do
    with true <- is_port(options.socket) || {:error, :invalid_socket},
         true <- is_pid(options.server) || {:error, :invalid_server},
         true <-
           (is_integer(options.max_frame_bytes) and options.max_frame_bytes >= 1) ||
             {:error, :invalid_frame_limit},
         true <-
           (is_integer(options.max_tasks) and options.max_tasks >= 1) ||
             {:error, :invalid_task_limit},
         true <-
           (is_integer(options.request_timeout) and options.request_timeout >= 1) ||
             {:error, :invalid_request_timeout},
         true <-
           (is_integer(options.max_pending_requests) and options.max_pending_requests >= 1) ||
             {:error, :invalid_pending_limit},
         true <-
           (is_integer(options.result_bytes) and options.result_bytes >= 1) ||
             {:error, :invalid_result_limit},
         true <-
           (is_integer(options.error_bytes) and options.error_bytes >= 1) ||
             {:error, :invalid_error_limit} do
      {:ok,
       %{
         socket: options.socket,
         server: options.server,
         max_frame_bytes: options.max_frame_bytes,
         max_buffer_bytes: options.max_frame_bytes * 2 + 8,
         max_tasks: options.max_tasks,
         request_timeout: options.request_timeout,
         max_pending_requests: options.max_pending_requests,
         result_bytes: options.result_bytes,
         error_bytes: options.error_bytes,
         buffer: <<>>,
         session: nil,
         pending: %{}
       }}
    else
      _ -> {:stop, :invalid_connection_options}
    end
  end

  @impl true
  def handle_info(:socket_ready, s) do
    case :inet.setopts(s.socket, active: :once) do
      :ok -> {:noreply, s}
      {:error, _} -> {:stop, :socket_unavailable, s}
    end
  end

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = s) when is_binary(bytes) do
    if byte_size(s.buffer) + byte_size(bytes) > s.max_buffer_bytes do
      _ = send_wire(s, Protocol.error(nil, "buffer_limit"))
      {:stop, :normal, s}
    else
      case Protocol.decode_frames(s.buffer <> bytes, s.max_frame_bytes) do
        {:ok, messages, buffer} ->
          case Enum.reduce_while(messages, %{s | buffer: buffer}, fn message, state ->
                 case request(message, state) do
                   {:ok, next} -> {:cont, next}
                   {:stop, next} -> {:halt, {:stop, next}}
                 end
               end) do
            {:stop, next} -> {:stop, :normal, next}
            next -> arm(next)
          end

        {:error, reason} ->
          _ = send_wire(s, Protocol.error(nil, protocol_error(reason)))
          {:stop, :normal, s}
      end
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = s), do: {:stop, :normal, s}
  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = s), do: {:stop, :normal, s}

  def handle_info({:request_timeout, request_id}, s) do
    case Map.pop(s.pending, request_id) do
      {nil, _} ->
        {:noreply, s}

      {_timer, pending} ->
        case send_wire(%{s | pending: pending}, Protocol.error(request_id, "request_timeout")) do
          {:ok, next} -> {:noreply, next}
          {:error, next} -> {:stop, :normal, next}
        end
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def handle_cast({:deliver, message}, s) do
    case send_wire(s, message) do
      {:ok, next} -> {:noreply, next}
      {:error, next} -> {:stop, :normal, next}
    end
  end

  def handle_cast(:close, s), do: {:stop, :normal, s}

  @impl true
  def handle_call({:reply, request_id, type, fields}, _from, s) do
    case take_pending(s, request_id) do
      {:ok, next} ->
        case send_wire(next, Protocol.reply(type, request_id, fields)) do
          {:ok, sent} -> {:reply, :ok, sent}
          {:error, sent} -> {:stop, :normal, {:error, :connection_closed}, sent}
        end

      :error ->
        {:reply, {:error, :unknown_request}, s}
    end
  end

  def handle_call({:error, request_id, code}, _from, s) do
    next =
      case take_pending(s, request_id) do
        {:ok, state} -> state
        :error -> s
      end

    case send_wire(next, Protocol.error(request_id, code)) do
      {:ok, sent} -> {:reply, :ok, sent}
      {:error, sent} -> {:stop, :normal, {:error, :connection_closed}, sent}
    end
  end

  @impl true
  def terminate(_reason, s) do
    Enum.each(s.pending, fn {_request_id, timer} -> Process.cancel_timer(timer) end)
    Server.disconnected(s.server, self())
    _ = :gen_tcp.close(s.socket)
    :ok
  end

  defp arm(s) do
    case :inet.setopts(s.socket, active: :once) do
      :ok -> {:noreply, s}
      {:error, _} -> {:stop, :socket_unavailable, s}
    end
  end

  defp request(%{"type" => "hello"} = message, %{session: nil} = s) do
    with {:ok, session} <- hello(message),
         :ok <- Server.hello(s.server, self(), session),
         {:ok, next} <- send_wire(%{s | session: session}, hello_reply(message, session)) do
      {:ok, next}
    else
      {:error, code} -> protocol_reply(s, message, code)
      _ -> protocol_reply(s, message, "unavailable")
    end
  end

  defp request(%{"type" => "hello"} = message, s), do: protocol_reply(s, message, "already_hello")

  defp request(%{"type" => type} = message, %{session: nil} = s)
       when type in [
              "register_tasks",
              "unregister_tasks",
              "enqueue",
              "status",
              "result",
              "cancel",
              "started",
              "succeeded",
              "failed",
              "heartbeat",
              "schedule",
              "cancel_schedule",
              "register_schedules"
            ],
       do: protocol_reply(s, message, "hello_required")

  defp request(%{"type" => "register_tasks"} = message, s) do
    with {:ok, tasks} <- task_list(message, s.max_tasks),
         :ok <- Server.register_tasks(s.server, self(), tasks),
         {:ok, next} <-
           send_wire(
             s,
             Protocol.reply("tasks_registered", Protocol.request_id(message), %{"tasks" => tasks})
           ) do
      {:ok, next}
    else
      {:error, code} -> protocol_reply(s, message, code)
      _ -> protocol_reply(s, message, "unavailable")
    end
  end

  defp request(%{"type" => "unregister_tasks"} = message, s) do
    with {:ok, tasks} <- task_list(message, s.max_tasks),
         :ok <- Server.unregister_tasks(s.server, self(), tasks),
         {:ok, next} <-
           send_wire(
             s,
             Protocol.reply("tasks_unregistered", Protocol.request_id(message), %{
               "tasks" => tasks
             })
           ) do
      {:ok, next}
    else
      {:error, code} -> protocol_reply(s, message, code)
      _ -> protocol_reply(s, message, "unavailable")
    end
  end

  defp request(%{"type" => "enqueue"} = message, s) do
    with :ok <- enqueue_message?(message),
         do: forward(s, message),
         else: (_ -> protocol_reply(s, message, "invalid_enqueue"))
  end

  defp request(%{"type" => type} = message, s) when type in ["status", "result", "cancel"] do
    with :ok <- job_message?(message),
         do: forward(s, message),
         else: (_ -> protocol_reply(s, message, "invalid_job_id"))
  end

  defp request(%{"type" => type} = message, s)
       when type in ["schedule", "cancel_schedule"],
       do: forward(s, message)

  defp request(%{"type" => "register_schedules"} = message, s),
    do: protocol_reply(s, message, "bulk_scheduling_unsupported")

  defp request(%{"type" => "started"} = message, s) do
    with {:ok, reservation_id, execution} <- execution_context(message),
         :ok <- Server.started(s.server, self(), reservation_id, execution),
         {:ok, next} <- send_wire(s, Protocol.reply("accepted", Protocol.request_id(message))) do
      {:ok, next}
    else
      {:error, code} -> protocol_reply(s, message, code)
      _ -> protocol_reply(s, message, "unknown_execution")
    end
  end

  defp request(%{"type" => "succeeded"} = message, s) do
    with {:ok, reservation_id, execution} <- execution_context(message),
         result = Map.get(message, "result"),
         {:ok, _} <- Protocol.json_bytes(result, s.result_bytes),
         :ok <- Server.complete(s.server, self(), reservation_id, execution, {:success, result}),
         {:ok, next} <- send_wire(s, Protocol.reply("accepted", Protocol.request_id(message))) do
      {:ok, next}
    else
      {:error, :json_too_large} -> protocol_reply(s, message, "result_too_large")
      {:error, code} -> protocol_reply(s, message, code)
      _ -> protocol_reply(s, message, "unknown_execution")
    end
  end

  defp request(%{"type" => "failed"} = message, s) do
    with {:ok, reservation_id, execution} <- execution_context(message),
         {:ok, error} <- failure(message, s.error_bytes),
         :ok <- Server.complete(s.server, self(), reservation_id, execution, {:failure, error}),
         {:ok, next} <- send_wire(s, Protocol.reply("accepted", Protocol.request_id(message))) do
      {:ok, next}
    else
      {:error, code} -> protocol_reply(s, message, code)
      _ -> protocol_reply(s, message, "unknown_execution")
    end
  end

  defp request(%{"type" => "heartbeat"} = message, s) do
    case send_wire(s, Protocol.reply("heartbeat_ok", Protocol.request_id(message))) do
      {:ok, next} -> {:ok, next}
      {:error, next} -> {:stop, next}
    end
  end

  defp request(message, s), do: protocol_reply(s, message, "unknown_message")

  defp forward(s, message) do
    request_id = Protocol.request_id(message)

    if map_size(s.pending) >= s.max_pending_requests do
      protocol_reply(s, message, "too_many_requests")
    else
      timer = Process.send_after(self(), {:request_timeout, request_id}, s.request_timeout)
      :ok = Server.request(s.server, self(), message)
      {:ok, %{s | pending: Map.put(s.pending, request_id, timer)}}
    end
  end

  defp protocol_reply(s, message, code) do
    case send_wire(s, Protocol.error(Protocol.request_id(message), code)) do
      {:ok, next} -> {:ok, next}
      {:error, next} -> {:stop, next}
    end
  end

  defp hello(%{"mode" => mode, "runtime_id" => runtime_id} = message)
       when mode in ["client", "embedded", "worker"] do
    capacity = Map.get(message, "max_concurrency", 0)

    if Protocol.identifier?(runtime_id) and is_integer(capacity) and capacity in 0..65_535 do
      {:ok, %{mode: mode, runtime_id: runtime_id, capacity: capacity}}
    else
      {:error, "invalid_hello"}
    end
  end

  defp hello(_), do: {:error, "invalid_hello"}

  defp hello_reply(message, session) do
    Protocol.reply("hello_ok", Protocol.request_id(message), %{
      "mode" => session.mode,
      "max_concurrency" => session.capacity
    })
  end

  defp task_list(%{"tasks" => tasks}, maximum) when is_list(tasks) and length(tasks) <= maximum do
    if Enum.all?(tasks, &Protocol.task_key?/1) and length(tasks) == length(Enum.uniq(tasks)),
      do: {:ok, tasks},
      else: {:error, "invalid_tasks"}
  end

  defp task_list(_, _), do: {:error, "invalid_tasks"}

  defp enqueue_message?(%{"task" => task, "args" => args} = message) do
    if Protocol.task_key?(task) and is_map(args) and not is_struct(args) and
         Protocol.json_value?(args) and
         (not Map.has_key?(message, "options") or
            (is_map(message["options"]) and not is_struct(message["options"]) and
               Protocol.json_value?(message["options"]))) do
      :ok
    else
      {:error, :invalid_enqueue}
    end
  end

  defp enqueue_message?(_), do: {:error, :invalid_enqueue}

  defp job_message?(%{"job_id" => id}) do
    case Tay.JobID.decode(id) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_job_id}
    end
  end

  defp job_message?(_), do: {:error, :invalid_job_id}

  defp execution_context(%{"reservation_id" => reservation_id, "execution_id" => execution}) do
    if Protocol.identifier?(reservation_id) and Protocol.identifier?(execution),
      do: {:ok, reservation_id, execution},
      else: {:error, "invalid_execution"}
  end

  defp execution_context(_), do: {:error, "invalid_execution"}

  defp failure(%{"error" => error}, max_bytes) when is_map(error) and not is_struct(error) do
    type = Map.get(error, "type")
    message = Map.get(error, "message")
    traceback = Map.get(error, "traceback")

    with {:ok, normalized} <-
           normalize_failure(%{}, [
             {"type", type, 128},
             {"message", message, max_bytes},
             {"traceback", traceback, max_bytes}
           ]),
         true <- map_size(normalized) > 0 || {:error, "invalid_failure"},
         {:ok, _} <- Protocol.json_bytes(normalized, max_bytes) do
      {:ok, normalized}
    else
      {:error, :json_too_large} -> {:error, "error_too_large"}
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_failure"}
    end
  end

  defp failure(_, _), do: {:error, "invalid_failure"}

  defp normalize_failure(map, []), do: {:ok, map}
  defp normalize_failure(map, [{_key, nil, _maximum} | rest]), do: normalize_failure(map, rest)

  defp normalize_failure(map, [{key, value, maximum} | rest]) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= maximum,
      do: normalize_failure(Map.put(map, key, value), rest),
      else: {:error, "invalid_failure"}
  end

  defp normalize_failure(_, _), do: {:error, "invalid_failure"}

  defp take_pending(s, request_id) when is_binary(request_id) do
    case Map.pop(s.pending, request_id) do
      {nil, _} ->
        :error

      {timer, pending} ->
        Process.cancel_timer(timer)
        {:ok, %{s | pending: pending}}
    end
  end

  defp take_pending(_, _), do: :error

  defp send_wire(s, message) do
    with {:ok, frame} <- Protocol.frame(message, s.max_frame_bytes),
         :ok <- :gen_tcp.send(s.socket, frame) do
      {:ok, s}
    else
      _ -> {:error, s}
    end
  end

  defp protocol_error(:frame_too_large), do: "frame_too_large"
  defp protocol_error(:malformed_json), do: "malformed_json"
  defp protocol_error(:unsupported_version), do: "unsupported_version"
  defp protocol_error(:unknown_message), do: "unknown_message"
  defp protocol_error(_), do: "invalid_frame"
end
