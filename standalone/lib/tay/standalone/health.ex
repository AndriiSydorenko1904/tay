defmodule Tay.Standalone.Health do
  @moduledoc false

  @spec check!() :: :ok
  def check!, do: check!(Tay.status())

  @doc false
  @spec check!(map()) :: :ok
  def check!(status) do
    with %{state: :ready} <- status,
         {:ok, config} <- Tay.Standalone.Config.load(),
         {:ok, socket} <- connect(config) do
      :ok = :gen_tcp.close(socket)
      :ok
    else
      reason -> raise "Tay standalone is not ready: #{inspect(reason)}"
    end
  end

  defp connect(%{socket_path: path}) when is_binary(path) do
    :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 1_000)
  end

  defp connect(%{http_port: port, http_ip: ip}) when is_integer(port) do
    address =
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, {0, 0, 0, 0}} -> {127, 0, 0, 1}
        {:ok, {0, 0, 0, 0, 0, 0, 0, 0}} -> {0, 0, 0, 0, 0, 0, 0, 1}
        {:ok, value} -> value
      end

    :gen_tcp.connect(address, port, [:binary, active: false], 1_000)
  end
end
