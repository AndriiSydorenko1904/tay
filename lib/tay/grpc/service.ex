defmodule Tay.GRPC.Service do
  @moduledoc false
  use GRPC.Server, service: Tay.Grpc.V1.Tay.Service

  alias Tay.Executor.{Protocol, Server}
  alias Tay.GRPC.Listener
  alias Tay.Grpc.V1.{EnqueueRequest, JobRequest, OperationReply}

  def enqueue(%EnqueueRequest{} = request, _stream) do
    with :ok <- task(request.task),
         {:ok, args} <- json_object(request.args_json),
         {:ok, options} <- json_object_or_empty(request.options_json) do
      call("enqueue", %{"task" => request.task, "args" => args, "options" => options})
    else
      {:error, code} -> raise_rpc(code)
    end
  end

  def get_job(%JobRequest{} = request, _stream), do: job_call("status", request.job_id)

  def cancel(%JobRequest{} = request, _stream), do: job_call("cancel", request.job_id)

  def get_result(%JobRequest{} = request, _stream), do: job_call("result", request.job_id)

  defp job_call(type, job_id) do
    if is_binary(job_id) and byte_size(job_id) in 1..128,
      do: call(type, %{"job_id" => job_id}),
      else: raise_rpc("invalid_job_id")
  end

  defp call(type, message) do
    with {:ok, %{engine_name: engine_name, executor_server: server} = runtime} <-
           Listener.runtime() do
      case Server.protocol_request(server, engine_name, Map.put(message, "type", type)) do
        {:ok, reply_type, fields} -> reply(reply_type, fields, runtime.max_message_bytes)
        {:error, code} -> raise_rpc(code)
        {:error, code, _fields} -> raise_rpc(code)
      end
    else
      _ -> raise_rpc("unavailable")
    end
  end

  defp reply(type, fields, max_message_bytes) do
    value = Map.merge(%{"type" => type}, fields)

    case Protocol.json_bytes(value, max_message_bytes) do
      {:ok, json} -> %OperationReply{json: json}
      _ -> raise_rpc("response_too_large")
    end
  end

  defp json_object(bytes) when is_binary(bytes) and byte_size(bytes) in 1..1_048_576 do
    try do
      case :json.decode(bytes) do
        value when is_map(value) and not is_struct(value) ->
          if Protocol.json_value?(value), do: {:ok, value}, else: {:error, "invalid_json_object"}

        _ ->
          {:error, "invalid_json_object"}
      end
    rescue
      _ -> {:error, "invalid_json_object"}
    catch
      _, _ -> {:error, "invalid_json_object"}
    end
  end

  defp json_object(_), do: {:error, "invalid_json_object"}
  defp json_object_or_empty(<<>>), do: {:ok, %{}}
  defp json_object_or_empty(bytes), do: json_object(bytes)

  defp task(value) when is_binary(value) do
    if Protocol.task_key?(value), do: :ok, else: {:error, "invalid_task"}
  end

  defp task(_), do: {:error, "invalid_task"}

  defp raise_rpc(code) do
    status =
      case code do
        "not_found" -> :not_found
        "capacity" -> :resource_exhausted
        "unavailable" -> :unavailable
        "unknown_outcome" -> :unavailable
        "result_not_ready" -> :failed_precondition
        "task_failed" -> :aborted
        _ -> :invalid_argument
      end

    raise GRPC.RPCError, status: status, message: code
  end
end
