defmodule Tay.Standalone.Config do
  @moduledoc false

  @data_default "/var/lib/tay"
  @socket_default "/run/tay/tay.sock"

  defstruct data_dir: @data_default,
            socket_path: @socket_default,
            initialize: :never

  @type t :: %__MODULE__{
          data_dir: String.t(),
          socket_path: String.t(),
          initialize: :never | :if_missing
        }

  @spec load(map()) :: {:ok, t()} | {:error, String.t()}
  def load(environment \\ System.get_env())

  def load(environment) when is_map(environment) do
    with {:ok, data_dir} <- path(environment, "TAY_DATA_DIR", @data_default, :data),
         {:ok, socket_path} <- path(environment, "TAY_SOCKET_PATH", @socket_default, :socket),
         :ok <- outside_data_dir(socket_path, data_dir),
         {:ok, initialize} <- initialize(environment) do
      {:ok,
       %__MODULE__{
         data_dir: data_dir,
         socket_path: socket_path,
         initialize: initialize
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
end
