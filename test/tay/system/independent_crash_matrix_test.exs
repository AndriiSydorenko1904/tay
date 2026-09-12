defmodule Tay.System.IndependentCrashMatrixTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true, timeout: 30_000
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  @name __MODULE__

  @cases for(
           point <- [:activated, :indexes_created, :pre_ready],
           do: {:activation, point, [1], nil}
         ) ++
           for(
             point <- [:pre_append, :post_append, :post_projection, :pre_reply, :post_reply],
             do:
               {:insert, point, if(point == :pre_append, do: [1], else: [1, 1]),
                if(point == :pre_append, do: nil, else: :scheduled)}
           ) ++
           for(
             point <- [:pre_append, :post_append, :post_projection],
             do:
               {:start, {:execution, 3, point},
                if(point == :pre_append, do: [1, 1], else: [1, 1, 3]),
                if(point == :pre_append, do: :available, else: :executing)}
           ) ++
           for(
             point <- [:pre_release, :released],
             do: {:start, {:execution, point}, [1, 1, 3], :executing}
           ) ++
           for(
             {operation, type, terminal} <- [{:finish, 4, :completed}, {:cancel, 5, :cancelled}],
             point <- [:pre_append, :post_append, :post_projection],
             do:
               {operation, {:execution, type, point},
                if(point == :pre_append, do: [1, 1, 3], else: [1, 1, 3, type]),
                if(point == :pre_append, do: :executing, else: terminal)}
           )

  for {operation, point, types, state} <- @cases do
    @operation operation
    @point point
    @types types
    @state state
    test "whole-VM SIGKILL at #{operation} #{inspect(point)} retains every observed ACK" do
      Process.flag(:trap_exit, true)
      path = NativeHelpers.path()
      oracles = path <> ".external-oracles"
      File.mkdir_p!(oracles)
      ack = Path.join(oracles, "acknowledgements")
      effect = Path.join(oracles, "effects")
      seed_id = Tay.JobID.new()
      target_id = Tay.JobID.new()

      on_exit(fn ->
        File.rm_rf!(path)
        File.rm_rf!(oracles)
      end)

      initialize_oracles(ack, effect, oracles)
      H.initialize(path)
      assert {:ok, seed_root} = EngineHelpers.restart(path, @name)

      assert {:ok, seed} =
               EngineWorker.new(%{"inert_seed" => true},
                 id: seed_id,
                 scheduled_at: Tay.Event.V1.max_time()
               )

      assert {:ok, %{id: ^seed_id}} = Tay.insert(seed, name: @name)
      append_synced(ack, "ACK:insert:" <> seed_id <> "\n")
      EngineHelpers.stop(seed_root)

      {output, exit_status} =
        NativeHelpers.child_elixir(script(@operation, @point), [path, ack, effect, target_id])

      assert exit_status != 0
      assert output =~ "BOUNDARY:" <> inspect(@point)
      refute output =~ "WATCHDOG"
      before = R.snapshot(path)
      mode = if System.get_env("TAY_TEST_SYNC") == "1", do: :sync, else: :write

      assert {:ok, %{record_count: count, mutation: :none, activation: :not_attempted}} =
               R.after_release(fn ->
                 Tay.Diagnostics.inspect(
                   data_dir: path,
                   durability: mode,
                   validated_filesystem: mode == :sync
                 )
               end)

      assert count == length(@types)
      assert R.snapshot(path) == before
      history = H.history(path)
      assert Enum.map(history, & &1.event.record_type) == @types
      candidate = H.replay(path)
      {:ok, raw_seed} = Tay.JobID.decode(seed_id)
      {:ok, raw_target} = Tay.JobID.decode(target_id)
      assert candidate.jobs[raw_seed].state == :scheduled

      if @state,
        do: assert(candidate.jobs[raw_target].state == @state),
        else: refute(Map.has_key?(candidate.jobs, raw_target))

      effects = File.read!(effect) |> String.split("\n", trim: true)

      cond do
        @operation in [:finish, :cancel] ->
          assert effects == ["EFFECT:" <> target_id <> ":1:3"]

        @point == {:execution, :released} ->
          assert effects in [[], ["EFFECT:" <> target_id <> ":1:3"]]

        true ->
          assert effects == []
      end

      # An observed external effect alone does not fabricate completion. Every
      # pre-finish/pre-cancel append retains the executing state and exact token.
      if @state == :executing, do: assert(candidate.jobs[raw_target].execution == 3)

      if @state in [:completed, :cancelled] do
        last = List.last(history)
        assert last.event.data["execution_token"] == 3

        if @state == :completed do
          assert last.event.data["outcome"] == 0
          assert last.event.data["disposition"] == 0
          assert last.event.data["diagnostic"] == nil
        end
      end

      acknowledgements = File.read!(ack) |> String.split("\n", trim: true)
      assert ("ACK:insert:" <> seed_id) in acknowledgements

      if @point == :post_reply,
        do: assert(("ACK:insert:" <> target_id) in acknowledgements)

      # Full fresh production semantic recovery, with execution disabled only
      # by the existing compile-test option: no reconciliation Events or repair.
      assert {:ok, recovered_root} = EngineHelpers.restart(path, @name)

      try do
        for "ACK:insert:" <> acknowledged_id <- acknowledgements do
          assert acknowledged_id in [seed_id, target_id]
          assert {:ok, %{id: ^acknowledged_id}} = Tay.get_job(acknowledged_id, name: @name)
          {:ok, raw} = Tay.JobID.decode(acknowledged_id)
          assert Map.has_key?(candidate.jobs, raw)
        end

        if @state do
          assert {:ok, %{state: recovered_state}} = Tay.get_job(target_id, name: @name)
          assert recovered_state == @state
        else
          assert {:error, :not_found} = Tay.get_job(target_id, name: @name)
        end
      after
        EngineHelpers.stop(recovered_root)
      end

      assert R.snapshot(path) == before
    end
  end

  defp initialize_oracles(ack, effect, directory) do
    append_synced(ack, "")
    append_synced(effect, "")

    if System.get_env("TAY_TEST_SYNC") == "1" do
      # Establish these external oracle directory entries before the killable
      # VM starts. This is test evidence, never a Tay recovery anchor.
      script = """
      import os, sys
      fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
      os.fsync(fd)
      os.close(fd)
      fd = os.open(os.path.dirname(sys.argv[1]), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
      os.fsync(fd)
      os.close(fd)
      """

      assert {"", 0} =
               System.cmd(System.find_executable("python3"), ["-c", script, directory],
                 stderr_to_stdout: true
               )
    end
  end

  defp append_synced(path, line) do
    File.open!(path, [:append, :binary, :raw], fn file ->
      :ok = :file.write(file, line)
      :ok = :file.sync(file)
    end)
  end

  defp script(operation, point) do
    """
    Process.flag(:trap_exit, true)
    Code.prepend_path(#{inspect(Application.app_dir(:stream_data, "ebin"))})
    {:ok, _} = Application.ensure_all_started(:tay)
    spawn(fn -> Process.sleep(8_000); IO.puts("WATCHDOG"); System.halt(124) end)
    Process.register(self(), :tay_crash_matrix_controller)
    [path, ack, effect, id] = System.argv()
    operation = #{inspect(operation)}
    target = #{inspect(point)}

    defmodule Tay.CrashMatrixOracle do
      def append(path, line) do
        File.open!(path, [:append, :binary, :raw], fn file ->
          :ok = :file.write(file, line)
          :ok = :file.sync(file)
        end)
      end
    end

    defmodule Tay.CrashMatrixWorker do
      use Tay.Worker, key: "worker.v1"
      def perform(job) do
        token = elem(job.revision, 4)
        Tay.CrashMatrixOracle.append(job.args["effect"],
          "EFFECT:" <> job.id <> ":" <> Integer.to_string(job.attempt) <> ":" <> Integer.to_string(token) <> "\\n")
        send(Process.whereis(:tay_crash_matrix_controller), :effect_observed)
        if job.args["finish"], do: :ok, else: (receive do :never -> :ok end)
      end
    end

    hook = fn point ->
      if point == target do
        if target == :post_reply do
          send(Process.whereis(:tay_crash_matrix_controller), {:post_reply_wait, self()})
          receive do :ack_logged -> :ok end
        end
        IO.puts("BOUNDARY:" <> inspect(point))
        System.cmd(System.find_executable("kill"), ["-KILL", System.pid()])
        System.halt(125)
      end
    end

    mode = if System.get_env("TAY_TEST_SYNC") == "1", do: :sync, else: :write
    {:ok, _root} = Tay.Test.EngineHelpers.restart(path, Tay.CrashMatrixEngine,
      workers: %{"worker.v1" => Tay.CrashMatrixWorker}, queues: [default: 1],
      durability: mode, validated_filesystem: mode == :sync,
      test_execution: true, test_hook: hook, execution_wake_ms: 10)

    if operation != :activation do
      schedule = if operation == :insert, do: Tay.Event.V1.max_time(), else: nil
      {:ok, job} = Tay.CrashMatrixWorker.new(%{"effect" => effect, "finish" => operation == :finish},
        id: id, scheduled_at: schedule, max_attempts: 1)
      {:ok, _} = Tay.insert(job, name: Tay.CrashMatrixEngine)
      Tay.CrashMatrixOracle.append(ack, "ACK:insert:" <> id <> "\\n")

      if target == :post_reply do
        receive do {:post_reply_wait, engine} -> send(engine, :ack_logged) end
      end

      if operation == :cancel do
        receive do :effect_observed -> :ok end
        Tay.cancel(id, name: Tay.CrashMatrixEngine)
      end
    end

    receive do :never -> :ok end
    """
  end
end
