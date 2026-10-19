defmodule Tay.Executor.Transport.Unix do
  @moduledoc false
  import Bitwise

  def open(nil, _mode, _private_directory, _owner), do: {:ok, nil, nil, nil}

  def open(path, mode, private_directory, owner) do
    with :ok <- prepare(path, private_directory),
         {:ok, listener} <- listen(path),
         :ok <- File.chmod(path, mode) do
      acceptor = spawn_link(fn -> acceptor_wait(owner, listener) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)
      send(acceptor, :accept)
      {:ok, listener, acceptor, Process.monitor(acceptor)}
    end
  end

  def close(listener, acceptor, path) do
    if is_port(listener), do: :gen_tcp.close(listener)

    if is_pid(acceptor) do
      Process.unlink(acceptor)
      Process.exit(acceptor, :shutdown)
    end

    if path, do: remove_socket(path)
    :ok
  end

  def valid_path?(path) when is_binary(path),
    do:
      Path.type(path) == :absolute and String.valid?(path) and byte_size(path) in 1..100 and
        not String.contains?(path, <<0>>)

  def valid_path?(_), do: false

  defp prepare(path, private_directory) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- protect_directory(Path.dirname(path), private_directory) do
      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, stat} ->
          if socket?(stat), do: reclaim_stale(path), else: {:error, :socket_path_exists}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp protect_directory(_path, false), do: :ok
  defp protect_directory(path, true), do: File.chmod(path, 0o700)

  defp reclaim_stale(path) do
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
      {:ok, stat} -> if socket?(stat), do: File.rm(path), else: {:error, :socket_path_exists}
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

  defp acceptor_wait(owner, listener) do
    receive do
      :accept -> acceptor_loop(owner, listener)
    end
  end

  defp acceptor_loop(owner, listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case :gen_tcp.controlling_process(socket, owner) do
          :ok -> send(owner, {:executor_accepted, socket})
          _ -> :gen_tcp.close(socket)
        end

        acceptor_loop(owner, listener)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        send(owner, :executor_accept_failed)
    end
  end

  defp remove_socket(path) do
    case File.lstat(path) do
      {:ok, stat} -> if socket?(stat), do: File.rm(path), else: :ok
      _ -> :ok
    end
  end

  defp socket?(%{mode: mode}) when is_integer(mode), do: (mode &&& 0o170000) == 0o140000
  defp socket?(_), do: false
end
