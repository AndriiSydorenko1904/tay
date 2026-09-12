defmodule Tay.Test.EngineWorker do
  @moduledoc false
  use Tay.Worker, key: "worker.v1"
  @impl true
  def perform(_), do: raise("Phase 4 executed a worker")
end

defmodule Tay.Test.EngineHelpers do
  @moduledoc false
  alias Tay.Test.EngineWorker

  def options(path, name, extra \\ []) do
    mode = if System.get_env("TAY_TEST_SYNC") == "1", do: :sync, else: :write

    Keyword.merge(
      [
        name: name,
        data_dir: path,
        workers: %{"worker.v1" => EngineWorker},
        durability: mode,
        validated_filesystem: mode == :sync,
        test_helper: true
      ],
      extra
    )
  end

  def start(path, name, extra \\ []), do: Tay.start_link(options(path, name, extra))

  def restart(path, name, extra \\ []),
    do: restart_until(path, name, extra, System.monotonic_time(:millisecond) + 5_000)

  # Test-only eventual-flock-release assertion. OTP wraps failed child starts;
  # retry ONLY ownership_busy, never an uncertain mutation or other diagnosis.
  defp restart_until(path, name, extra, deadline) do
    result = start(path, name, extra)

    if busy?(result) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      restart_until(path, name, extra, deadline)
    else
      result
    end
  end

  defp busy?({:error, nested}), do: busy?(nested)
  defp busy?({:shutdown, nested}), do: busy?(nested)
  defp busy?({:failed_to_start_child, Tay.Engine, nested}), do: busy?(nested)
  defp busy?(%Tay.Storage.Recovery.Error{kind: :ownership_busy}), do: true
  defp busy?(%Tay.Error{reason: {:recovery, error}}), do: busy?(error)
  defp busy?(_), do: false

  def stop(root) do
    if Process.alive?(root), do: Supervisor.stop(root)
  end

  def eventually(fun, tries \\ 200)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, tries) do
    case fun.() do
      false ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      nil ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      other ->
        other
    end
  end

  def engine(root),
    do:
      root
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Tay.Engine, pid, _, _} -> pid
        _ -> nil
      end)
end
