defmodule Tay.Standalone.Health do
  @moduledoc false

  @spec check!() :: :ok
  def check! do
    with %{state: :ready} <- Tay.status(),
         {:ok, config} <- Tay.Standalone.Config.load(),
         {:ok, socket} <- connect(config.socket_path) do
      :ok = :gen_tcp.close(socket)
      :ok
    else
      reason -> raise "Tay standalone is not ready: #{inspect(reason)}"
    end
  end

  defp connect(path) do
    :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 1_000)
  end
end
