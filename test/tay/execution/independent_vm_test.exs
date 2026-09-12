defmodule Tay.Execution.IndependentVMTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.NativeHelpers

  test "abrupt whole-VM loss replays an interrupted attempt with a fresh physical token" do
    path = NativeHelpers.path()
    oracle = path <> ".external-effects"

    on_exit(fn ->
      File.rm_rf!(path)
      File.rm(oracle)
    end)

    H.initialize(path)
    id = Tay.JobID.new()

    first = script(:crash)
    assert {"EFFECT:1:2\n", 23} = NativeHelpers.child_elixir(first, [path, oracle, id])

    # This oracle is outside Tay storage and observed after the entire callback
    # VM is gone. It records an external effect, not a fabricated completion ACK.
    assert File.read!(oracle) == id <> ":1:2\n"
    [insert, started] = H.history(path)
    assert insert.event.record_type == 1
    assert started.event.record_type == 3
    assert started.event.data["attempt"] == 1
    assert started.sequence == 2

    second = script(:complete)
    assert {"COMPLETED:1\n", 0} = NativeHelpers.child_elixir(second, [path, oracle, id])
    assert File.read!(oracle) == id <> ":1:2\n" <> id <> ":1:5\n"

    history = H.history(path)
    assert Enum.map(history, & &1.event.record_type) == [1, 3, 4, 2, 3, 4]
    [_, first_start, interrupted, available, second_start, finished] = history
    assert interrupted.event.data["execution_token"] == first_start.sequence
    assert interrupted.event.data["outcome"] == 3
    assert interrupted.event.data["diagnostic"] == %{"code" => 7, "version" => 1}
    assert interrupted.event.data["disposition"] == 1
    assert interrupted.event.data["next_attempt"] == 1
    assert available.event.data["due_at"] == interrupted.event.data["next_due_at"]
    assert second_start.event.data["attempt"] == first_start.event.data["attempt"]
    assert second_start.sequence != first_start.sequence
    assert finished.event.data["execution_token"] == second_start.sequence
    assert finished.event.data["outcome"] == 0
    assert finished.event.data["disposition"] == 0
    {:ok, raw} = Tay.JobID.decode(id)
    recovered = H.replay(path).jobs[raw]
    assert recovered.state == :completed and recovered.attempt == 1
    assert recovered.revision == 6
  end

  defp script(mode) do
    callback =
      if mode == :crash,
        do:
          "send(Process.whereis(:tay_vm_controller), {:effect, job.attempt, sequence}); receive do :never -> :ok end",
        else: ":ok"

    action =
      if mode == :crash do
        """
        {:ok, job} = Tay.IndependentVMWorker.new(%{"oracle" => oracle}, id: id, max_attempts: 1)
        {:ok, _} = Tay.insert(job, name: Tay.IndependentVMEngine)
        receive do
          {:effect, attempt, sequence} ->
            IO.puts("EFFECT:" <> Integer.to_string(attempt) <> ":" <> Integer.to_string(sequence))
            System.halt(23)
        after
          8_000 -> raise "independent callback did not enter"
        end
        """
      else
        """
        deadline = System.monotonic_time(:millisecond) + 8_000
        job = Tay.IndependentVMAwait.completed(id, deadline)
        IO.puts("COMPLETED:" <> Integer.to_string(job.attempt))
        Supervisor.stop(root)
        """
      end

    """
    Process.flag(:trap_exit, true)
    # The test-built tay.app names its test-only dependency. NativeHelpers adds
    # Tay's exact ebin; retain the corresponding dependency from this same build.
    Code.prepend_path(#{inspect(Application.app_dir(:stream_data, "ebin"))})
    {:ok, _} = Application.ensure_all_started(:tay)
    Process.register(self(), :tay_vm_controller)
    [path, oracle, id] = System.argv()

    defmodule Tay.IndependentVMWorker do
      use Tay.Worker, key: "independent.execution.v1"
      def perform(job) do
        sequence = elem(job.revision, 4)
        line = job.id <> ":" <> Integer.to_string(job.attempt) <> ":" <> Integer.to_string(sequence) <> "\\n"
        File.write!(job.args["oracle"], line, [:append])
        #{callback}
      end
    end

    defmodule Tay.IndependentVMAwait do
      def completed(id, deadline) do
        # Only successful reads are polled. No failed mutation or ambiguous RPC
        # is retried, and the single insertion above is submitted exactly once.
        case Tay.get_job(id, name: Tay.IndependentVMEngine) do
          {:ok, %{state: :completed} = job} -> job
          {:ok, %{state: state}} when state in [:retryable, :available, :executing] ->
            if System.monotonic_time(:millisecond) >= deadline, do: raise("completion deadline")
            Process.sleep(5)
            completed(id, deadline)
          _ -> raise "unexpected independent recovery result"
        end
      end
    end

    mode = if System.get_env("TAY_TEST_SYNC") == "1", do: :sync, else: :write
    # This existing test helper retries ONLY a positively identified ownership
    # busy acquisition while the prior native helper closes after VM death.
    {:ok, root} = Tay.Test.EngineHelpers.restart(path, Tay.IndependentVMEngine,
      workers: %{"independent.execution.v1" => Tay.IndependentVMWorker},
      queues: [default: 1], durability: mode, validated_filesystem: mode == :sync,
      test_execution: true, execution_wake_ms: 10)
    #{action}
    """
  end
end
