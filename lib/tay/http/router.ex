defmodule Tay.HTTP.Router do
  @moduledoc false
  @behaviour Plug

  alias Tay.Executor.{Protocol, Server}

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, options) do
    dispatch(conn, options)
  rescue
    error ->
      require Logger
      Logger.error("Tay HTTP request failed: #{Exception.message(error)}")
      json(conn, 500, %{"error" => %{"code" => "internal"}})
  end

  defp dispatch(%Plug.Conn{method: "POST", path_info: ["jobs"]} = conn, options) do
    with :ok <- content_type(conn),
         {:ok, body, conn} <- read_body(conn, options.max_body_bytes),
         {:ok, request} <- decode_object(body),
         :ok <- enqueue_request(request),
         result <-
           Server.protocol_request(options.executor_server, options.engine_name, %{
             "type" => "enqueue",
             "task" => request["task"],
             "args" => request["args"],
             "options" => Map.get(request, "options", %{})
           }) do
      respond(conn, result, 201, options.max_body_bytes)
    else
      {:error, reason, conn} -> error(conn, reason)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp dispatch(%Plug.Conn{method: "POST", path_info: ["workers"]} = conn, options) do
    with :ok <- content_type(conn),
         {:ok, body, conn} <- read_body(conn, options.max_body_bytes),
         {:ok, request} <- decode_object(body),
         {:ok, token} <-
           Server.register_http_worker(
             options.executor_server,
             request["runtime_id"],
             request["tasks"],
             request["capacity"],
             Map.get(request, "queue", "default")
           ) do
      json(conn, 201, %{"worker_token" => token})
    else
      {:error, reason, conn} -> error(conn, reason)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp dispatch(%Plug.Conn{method: "POST", path_info: ["queues", queue, "claim"]} = conn, options) do
    with {:ok, worker, ^queue} <- authenticated_worker(conn, options),
         result <- Tay.HTTP.WorkerSession.claim(worker) do
      case result do
        {:ok, message} -> json(conn, 200, message)
        :empty -> Plug.Conn.send_resp(conn, 204, "")
        {:error, code} -> error(conn, code)
      end
    else
      {:ok, _, _} -> error(conn, "wrong_queue")
      {:error, code} -> error(conn, code)
    end
  end

  defp dispatch(%Plug.Conn{method: "POST", path_info: ["workers", action]} = conn, options)
       when action in ["started", "complete"] do
    with {:ok, worker, _queue} <- authenticated_worker(conn, options),
         :ok <- content_type(conn),
         {:ok, body, conn} <- read_body(conn, options.max_body_bytes),
         {:ok, request} <- decode_object(body),
         :ok <- execution_context(request),
         :ok <- worker_event(action, options, worker, request) do
      json(conn, 200, %{"type" => "accepted"})
    else
      {:error, code, conn} -> error(conn, code)
      {:error, code} -> error(conn, code)
    end
  end

  defp dispatch(%Plug.Conn{method: "DELETE", path_info: ["workers"]} = conn, options) do
    with {:ok, worker, _queue} <- authenticated_worker(conn, options) do
      Tay.Executor.Connection.close(worker)
      json(conn, 200, %{"type" => "closed"})
    else
      {:error, code} -> error(conn, code)
    end
  end

  defp dispatch(%Plug.Conn{method: method, path_info: ["jobs", id | rest]} = conn, options)
       when method in ["GET", "DELETE"] do
    kind =
      case {method, rest} do
        {"GET", []} -> "status"
        {"DELETE", []} -> "cancel"
        {"GET", ["result"]} -> "result"
        _ -> nil
      end

    cond do
      is_nil(kind) ->
        error(conn, "not_found")

      not Protocol.identifier?(id) ->
        error(conn, "invalid_job_id")

      true ->
        Server.protocol_request(options.executor_server, options.engine_name, %{
          "type" => kind,
          "job_id" => id
        })
        |> then(&respond(conn, &1, 200, options.max_body_bytes))
    end
  end

  defp dispatch(conn, _options), do: error(conn, "not_found")

  defp authenticated_worker(conn, options) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) == 43 ->
        Server.http_worker(options.executor_server, token)

      _ ->
        {:error, "unauthorized"}
    end
  end

  defp execution_context(%{"reservation_id" => reservation, "execution_id" => execution}) do
    if Protocol.identifier?(reservation) and Protocol.identifier?(execution),
      do: :ok,
      else: {:error, "invalid_execution"}
  end

  defp execution_context(_), do: {:error, "invalid_execution"}

  defp worker_event("started", options, worker, request) do
    Server.started(
      options.executor_server,
      worker,
      request["reservation_id"],
      request["execution_id"]
    )
  end

  defp worker_event("complete", options, worker, request) do
    result =
      case request do
        %{"outcome" => "success", "result" => value} ->
          if match?({:ok, _}, Protocol.json_bytes(value, options.result_bytes)),
            do: {:ok, {:success, value}},
            else: {:error, "result_too_large"}

        %{"outcome" => "failure", "error" => value} when is_map(value) ->
          if not is_struct(value) and
               match?({:ok, _}, Protocol.json_bytes(value, options.error_bytes)),
             do: {:ok, {:failure, value}},
             else: {:error, "error_too_large"}

        _ ->
          {:error, "invalid_completion"}
      end

    with {:ok, outcome} <- result do
      Server.complete(
        options.executor_server,
        worker,
        request["reservation_id"],
        request["execution_id"],
        outcome
      )
    end
  end

  defp content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [value] ->
        if value |> String.downcase() |> String.split(";", parts: 2) |> hd() |> String.trim() ==
             "application/json",
           do: :ok,
           else: {:error, "unsupported_media_type"}

      _ ->
        {:error, "unsupported_media_type"}
    end
  end

  defp read_body(conn, limit), do: read_body(conn, limit, [])

  defp read_body(conn, limit, parts) when limit >= 0 do
    case Plug.Conn.read_body(conn, length: limit + 1) do
      {:ok, chunk, conn} when byte_size(chunk) <= limit ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | parts])), conn}

      {:more, chunk, conn} when byte_size(chunk) <= limit ->
        read_body(conn, limit - byte_size(chunk), [chunk | parts])

      {:ok, _, conn} ->
        {:error, "request_too_large", conn}

      {:more, _, conn} ->
        {:error, "request_too_large", conn}

      {:error, _} ->
        {:error, "invalid_request", conn}
    end
  end

  defp decode_object(body) do
    try do
      case :json.decode(body) do
        value when is_map(value) and not is_struct(value) ->
          if Protocol.json_value?(value), do: {:ok, value}, else: {:error, "invalid_json_object"}

        _ ->
          {:error, "invalid_json_object"}
      end
    rescue
      _ -> {:error, "invalid_json_object"}
    end
  end

  defp enqueue_request(request) do
    valid_keys = Enum.all?(Map.keys(request), &(&1 in ["task", "args", "options"]))

    if valid_keys and Protocol.task_key?(request["task"]) and
         is_map(request["args"]) and not is_struct(request["args"]) and
         is_map(Map.get(request, "options", %{})) and
         not is_struct(Map.get(request, "options", %{})),
       do: :ok,
       else: {:error, "invalid_enqueue"}
  end

  defp respond(conn, {:ok, type, fields}, status, limit) do
    value = Map.put(fields, "type", type)

    case Protocol.json_bytes(value, limit) do
      {:ok, body} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, body)

      _ ->
        error(conn, "response_too_large")
    end
  end

  defp respond(conn, {:error, code}, _status, _limit), do: error(conn, code)
  defp respond(conn, {:error, code, fields}, _status, _limit), do: error(conn, code, fields)

  defp error(conn, code, fields \\ %{}) do
    status =
      case code do
        "not_found" -> 404
        "unknown_worker" -> 401
        "unauthorized" -> 401
        "wrong_queue" -> 409
        "capacity" -> 429
        "result_not_ready" -> 409
        "task_failed" -> 409
        "unavailable" -> 503
        "unknown_outcome" -> 503
        "request_too_large" -> 413
        "response_too_large" -> 500
        "unsupported_media_type" -> 415
        _ -> 400
      end

    json(conn, status, %{"error" => Map.put(fields, "code", code)})
  end

  defp json(conn, status, value) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, :json.encode(value) |> IO.iodata_to_binary())
  end
end
