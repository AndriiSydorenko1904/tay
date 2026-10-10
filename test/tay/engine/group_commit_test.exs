defmodule Tay.Engine.GroupCommitTest do
  use ExUnit.Case, async: false
  @moduletag :linux_sync

  if :os.type() != {:unix, :linux} or System.get_env("TAY_TEST_SYNC") != "1" do
    @moduletag skip: "requires explicitly validated local Linux test volume and TAY_TEST_SYNC=1"
  end

  alias Tay.Storage.Writer
  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: Recovery
  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    Recovery.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "concurrent inserts share one fsync and no ACK crosses the fsync boundary", %{path: path} do
    parent = self()
    handler = "group-commit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:tay, :storage, :group_commit],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    hook = fn
      :append_synced, _native ->
        send(parent, {:fsync, self()})

        receive do
          :release_fsync -> :ok
        end

      _, _ ->
        :ok
    end

    {:ok, root} =
      EngineHelpers.start(path, @name,
        group_commit_interval_ms: 20,
        writer_hook: hook,
        client_slots: 8
      )

    jobs = for n <- 1..4, do: intent!(%{"n" => n})
    calls = Enum.map(jobs, &Task.async(fn -> Tay.insert(&1, name: @name, timeout: 2_000) end))

    assert_receive {:fsync, writer}, 1_000
    refute Enum.any?(calls, &match?({:ok, _}, Task.yield(&1, 0)))
    send(writer, :release_fsync)
    assert Enum.all?(calls, &match?({:ok, {:ok, _}}, Task.yield(&1, 2_000)))
    refute_receive {:fsync, _}, 50

    assert_receive {:telemetry, [:tay, :storage, :group_commit], measurements, %{engine: @name}}

    assert measurements.batch_size == 4
    assert measurements.wait_time > 0
    assert measurements.fsync_duration >= 0

    state = :sys.get_state(EngineHelpers.engine(root))

    assert {:ok, [4, 3, 2, 1]} =
             Writer.reduce(state.writer, [], fn record, _, acc -> [record.sequence | acc] end)

    EngineHelpers.stop(root)
  end

  test "fsync failure returns no success for any request in the batch", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name, group_commit_interval_ms: 10)
    writer = :sys.get_state(EngineHelpers.engine(root)).writer
    :ok = Writer.inject_fault(writer, :sync, 1, :error, 5)

    calls =
      for n <- 1..3,
          do: Task.async(fn -> Tay.insert(intent!(%{"n" => n}), name: @name, timeout: 300) end)

    results = Enum.map(calls, &Task.await(&1, 1_000))
    assert Enum.all?(results, &match?({:error, %{kind: :unknown_outcome}}, &1))
    assert EngineHelpers.eventually(fn -> Tay.status(name: @name).state == :failed end)
    EngineHelpers.stop(root)
  end

  test "drain flushes a pending batch instead of waiting for its interval", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name, group_commit_interval_ms: 1_000)
    insert = Task.async(fn -> Tay.insert(intent!(%{}), name: @name, timeout: 2_000) end)
    Process.sleep(20)
    started = System.monotonic_time(:millisecond)
    assert :ok = Tay.drain(name: @name, timeout: 2_000)
    assert {:ok, {:ok, _}} = Task.yield(insert, 2_000)
    assert System.monotonic_time(:millisecond) - started < 900
    EngineHelpers.stop(root)
  end

  test "interval zero keeps one immediate fsync per append", %{path: path} do
    parent = self()
    hook = fn tag, _ -> if tag == :append_synced, do: send(parent, :fsync) end
    {:ok, root} = EngineHelpers.start(path, @name, group_commit_interval_ms: 0, writer_hook: hook)
    assert {:ok, _} = Tay.insert(intent!(%{"n" => 1}), name: @name)
    assert_receive :fsync
    assert {:ok, _} = Tay.insert(intent!(%{"n" => 2}), name: @name)
    assert_receive :fsync
    EngineHelpers.stop(root)
  end

  test "shutdown resolves pending callers without hanging", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name, group_commit_interval_ms: 1_000)
    insert = Task.async(fn -> Tay.insert(intent!(%{}), name: @name, timeout: 2_000) end)
    Process.sleep(20)
    EngineHelpers.stop(root)
    assert {:ok, _} = Task.yield(insert, 2_000)
  end

  defp intent!(args) do
    {:ok, intent} = EngineWorker.new(args)
    intent
  end
end
