defmodule Tay.Executor.SocketPath do
  @moduledoc """
  Deterministic local Executor Protocol v1 socket discovery.

  The same algorithm is implemented by the reference SDKs: an explicit path
  wins, followed by `TAY_SOCKET_PATH`, then an existing shared `/run/tay`
  directory, a usable XDG runtime directory, a usable `TMPDIR`, and finally a
  per-UID `/tmp` directory. Private automatic paths own their final directory
  and request mode `0700`; shared/explicit/environment paths
  never cause Tay to chmod a caller-owned parent directory.
  """

  @max_path_bytes 100
  import Bitwise

  @enforce_keys [:path, :private_directory, :source]
  defstruct [:path, :private_directory, :source]
  @type t :: %__MODULE__{path: binary() | nil, private_directory: boolean(), source: atom()}

  @doc "Freezes a resolved path and its directory policy for handoff to the Engine."
  def freeze(resolution), do: struct!(__MODULE__, resolution)

  @type resolved :: %{path: binary() | nil, private_directory: boolean(), source: atom()}

  @spec resolve(:auto | nil | binary() | t(), keyword()) :: {:ok, resolved()} | {:error, atom()}
  def resolve(setting \\ :auto, options \\ [])

  # A frozen endpoint must never consult the receiving process's environment.
  def resolve(%__MODULE__{} = socket, options) do
    cond do
      not Keyword.keyword?(options) -> {:error, :invalid_socket_options}
      valid_resolution?(socket) -> {:ok, socket}
      true -> {:error, :invalid_socket_path}
    end
  end

  def resolve(setting, options) when setting in [:auto, nil] or is_binary(setting) do
    with true <- Keyword.keyword?(options) || {:error, :invalid_socket_options},
         env <- Keyword.get(options, :env, System.get_env()),
         usable_directory <- Keyword.get(options, :usable_directory, &usable_directory?/2),
         directory_exists <- Keyword.get(options, :directory_exists, &File.dir?/1),
         true <- is_map(env) || {:error, :invalid_socket_environment},
         true <- is_function(directory_exists, 1) || {:error, :invalid_socket_options},
         true <- is_function(usable_directory, 2) || {:error, :invalid_socket_options} do
      case setting do
        nil -> {:ok, %{path: nil, private_directory: false, source: :disabled}}
        :auto -> automatic(env, options, usable_directory, directory_exists)
        path -> explicit(path, :explicit)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_socket_options}
    end
  end

  def resolve(_, _), do: {:error, :invalid_socket_path}

  defp valid_resolution?(%{path: nil, private_directory: false, source: :disabled}), do: true

  defp valid_resolution?(%{path: path, private_directory: private, source: source}) do
    source in [:explicit, :environment, :shared_runtime, :xdg_runtime, :tmpdir, :tmp] and
      private == source in [:xdg_runtime, :tmpdir, :tmp] and is_binary(path) and
      valid_raw_path?(path)
  end

  defp automatic(env, options, usable_directory, directory_exists) do
    case env_path(env, "TAY_SOCKET_PATH") do
      nil ->
        if directory_exists.("/run/tay"),
          do:
            {:ok, %{path: "/run/tay/tay.sock", private_directory: false, source: :shared_runtime}},
          else: runtime_path(env, options, usable_directory)

      path ->
        explicit(path, :environment)
    end
  end

  defp runtime_path(env, options, usable_directory) do
    uid = Keyword.get_lazy(options, :uid, &uid/0)

    if valid_uid?(uid) do
      xdg = env_path(env, "XDG_RUNTIME_DIR")
      tmp = env_path(env, "TMPDIR")

      candidates = [
        {:xdg_runtime, xdg && Path.join([xdg, "tay", "tay.sock"])},
        {:tmpdir, tmp && Path.join([tmp, "tay-#{uid}", "tay.sock"])},
        {:tmp, Path.join(["/tmp", "tay-#{uid}", "tay.sock"])}
      ]

      Enum.find_value(candidates, {:error, :no_usable_socket_path}, fn {source, path} ->
        if automatic_candidate?(path, uid, usable_directory),
          do: {:ok, %{path: Path.expand(path), private_directory: true, source: source}},
          else: false
      end)
    else
      {:error, :invalid_uid}
    end
  end

  defp explicit(path, source) when is_binary(path) do
    if valid_raw_path?(path) do
      path = Path.expand(path)
      {:ok, %{path: path, private_directory: false, source: source}}
    else
      {:error, :invalid_socket_path}
    end
  end

  defp automatic_candidate?(nil, _, _), do: false

  defp automatic_candidate?(path, uid, usable_directory) when is_binary(path) do
    path = Path.expand(path)
    parent = path |> Path.dirname() |> Path.dirname()
    valid_path?(path) and usable_directory.(parent, uid)
  end

  defp automatic_candidate?(_, _, _), do: false

  defp env_path(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp valid_path?(path) do
    Path.type(path) == :absolute and String.valid?(path) and byte_size(path) in 1..@max_path_bytes and
      not String.contains?(path, <<0>>)
  end

  defp valid_raw_path?(path), do: valid_path?(path)

  defp valid_uid?(uid), do: is_integer(uid) and uid >= 0

  defp usable_directory?(path, uid) do
    with true <- File.dir?(path),
         {:ok, %{mode: mode, uid: owner, gid: group}} <- File.stat(path),
         true <- is_integer(mode) and is_integer(owner) and is_integer(group) do
      cond do
        owner == uid -> accessible?(mode, 0o300)
        Enum.member?(groups(), group) -> accessible?(mode, 0o030)
        true -> accessible?(mode, 0o003)
      end
    else
      _ -> false
    end
  end

  # A parent must be searchable as well as writable: without execute/search
  # permission a process cannot create the private final runtime directory.
  defp accessible?(mode, required), do: (mode &&& required) == required

  defp groups do
    :os.cmd(~c"id -G")
    |> to_string()
    |> String.split()
    |> Enum.flat_map(fn value ->
      case Integer.parse(value) do
        {group, ""} -> [group]
        _ -> []
      end
    end)
  end

  defp uid do
    case :os.cmd(~c"id -u") |> to_string() |> String.trim() |> Integer.parse() do
      {value, ""} when value >= 0 -> value
      _ -> -1
    end
  end
end
