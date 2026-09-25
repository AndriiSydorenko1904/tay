defmodule Tay.Standalone.Config do
  @moduledoc false

  @data_default "/var/lib/tay"
  @socket_default "/run/tay/tay.sock"

  defstruct data_dir: @data_default,
            socket_path: @socket_default,
            initialize: :never,
            max_jobs: 100_000,
            max_state_bytes: 268_435_456,
            max_state_nodes: 2_000_000,
            max_terminal_jobs: 5_000,
            terminal_retention: {:hours, 24}

  @type t :: %__MODULE__{
          data_dir: String.t(),
          socket_path: String.t(),
          initialize: :never | :if_missing,
          max_jobs: non_neg_integer(),
          max_state_bytes: non_neg_integer(),
          max_state_nodes: non_neg_integer(),
          max_terminal_jobs: non_neg_integer(),
          terminal_retention: {:minutes, pos_integer()} | {:hours, pos_integer()}
        }

  @spec load(map()) :: {:ok, t()} | {:error, String.t()}
  def load(environment \\ System.get_env())

  def load(environment) when is_map(environment) do
    with {:ok, data_dir} <- path(environment, "TAY_DATA_DIR", @data_default, :data),
         {:ok, socket_path} <- path(environment, "TAY_SOCKET_PATH", @socket_default, :socket),
         :ok <- outside_data_dir(socket_path, data_dir),
         {:ok, initialize} <- initialize(environment),
         {:ok, max_jobs} <- nonnegative(environment, "TAY_MAX_JOBS", 100_000),
         {:ok, max_state_bytes} <-
           nonnegative(environment, "TAY_MAX_STATE_BYTES", 268_435_456),
         {:ok, max_state_nodes} <-
           nonnegative(environment, "TAY_MAX_STATE_NODES", 2_000_000),
         {:ok, max_terminal_jobs} <-
           nonnegative(environment, "TAY_MAX_TERMINAL_JOBS", 5_000),
         {:ok, terminal_retention} <- terminal_retention(environment) do
      {:ok,
       %__MODULE__{
         data_dir: data_dir,
         socket_path: socket_path,
         initialize: initialize,
         max_jobs: max_jobs,
         max_state_bytes: max_state_bytes,
         max_state_nodes: max_state_nodes,
         max_terminal_jobs: max_terminal_jobs,
         terminal_retention: terminal_retention
       }}
    end
  end

  def load(_), do: {:error, "environment must be a string map"}

  defp path(environment, name, default, kind) do
    value = Map.get(environment, name, default)

    cond do
      not is_binary(value) ->
        {:error, "#{name} must be a path string"}

      not String.valid?(value) ->
        {:error, "#{name} must contain valid UTF-8"}

      String.trim(value) == "" ->
        {:error, "#{name} must not be blank"}

      String.contains?(value, <<0>>) ->
        {:error, "#{name} must not contain NUL bytes"}

      Path.type(value) != :absolute ->
        {:error, "#{name} must be an absolute path"}

      kind == :socket and byte_size(value) > 100 ->
        {:error, "#{name} must be at most 100 bytes"}

      true ->
        {:ok, Path.expand(value)}
    end
  end

  defp outside_data_dir(socket_path, data_dir) do
    if socket_path == data_dir or String.starts_with?(socket_path, data_dir <> "/") do
      {:error, "TAY_SOCKET_PATH must be outside TAY_DATA_DIR"}
    else
      :ok
    end
  end

  defp initialize(environment) do
    case Map.get(environment, "TAY_INITIALIZE_IF_MISSING", "false") do
      value when value in ["true", "TRUE", "1"] ->
        {:ok, :if_missing}

      value when value in ["false", "FALSE", "0"] ->
        {:ok, :never}

      value ->
        {:error,
         "TAY_INITIALIZE_IF_MISSING must be one of true, false, TRUE, FALSE, 1, or 0; got: #{inspect(value)}"}
    end
  end

  defp nonnegative(environment, name, default) do
    case Map.get(environment, name, Integer.to_string(default)) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} when number >= 0 -> {:ok, number}
          _ -> {:error, "#{name} must be a non-negative integer"}
        end

      _ ->
        {:error, "#{name} must be a non-negative integer"}
    end
  end

  defp terminal_retention(environment) do
    value = Map.get(environment, "TAY_TERMINAL_RETENTION", "24h")

    with value when is_binary(value) <- value,
         [_, amount, unit] <- Regex.run(~r/\A([1-9][0-9]*)(m|h|d)\z/, value),
         {amount, ""} <- Integer.parse(amount),
         retention <- retention(amount, unit),
         :ok <- Tay.Storage.V2.Retention.validate(retention) do
      {:ok, retention}
    else
      _ ->
        {:error,
         "TAY_TERMINAL_RETENTION must use a positive duration such as 30m, 1h, 24h, or 7d"}
    end
  end

  defp retention(amount, "m"), do: {:minutes, amount}
  defp retention(amount, "h"), do: {:hours, amount}
  defp retention(amount, "d"), do: {:hours, amount * 24}
end
