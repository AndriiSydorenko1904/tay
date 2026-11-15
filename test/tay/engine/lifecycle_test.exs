defmodule Tay.Engine.GenerationTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Tay.Test.{NativeHelpers, EngineWorker}
  alias Tay.Test.EngineHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Engine.Admission
  alias Tay.Storage.Writer
  @name __MODULE__
  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "same recovered Writer and helper remain sole owners through activation and append", %{
    path: path
  } do
    parent = self()

    hook = fn tag, native ->
      if tag in [:recovery_acquired, :recovery_replayed, :recovery_promoted, :append_written],
        do: send(parent, {:owner, tag, self(), native.port, native.facts.os_pid})

      :ok
    end

    {:ok, root} = H.start(path, @name, writer_hook: hook)
    assert_receive {:owner, :recovery_acquired, writer, port, os_pid}

    for tag <- [:recovery_replayed, :recovery_promoted],
        do: assert_receive({:owner, ^tag, ^writer, ^port, ^os_pid})

    {:ok, _} = Tay.insert(EngineWorker.new(%{}), name: @name)
    assert_receive {:owner, :append_written, ^writer, ^port, ^os_pid}
    assert {:error, :admission_reference_required} = Writer.append(writer, 1, 1, <<>>)
    assert {:error, _} = H.start(path, Tay.Test.OtherEngine)
    H.stop(root)
  end

  test "recovering is visible without a synchronous call into blocked Writer", %{path: path} do
    parent = self()

    hook = fn tag, _ ->
      if tag == :recovery_replayed do
        send(parent, {:waiting, self()})

        receive do
          :continue -> :ok
        end
      end

      :ok
    end

    task =
      Task.async(fn ->
        {:ok, root} = H.start(path, @name, writer_hook: hook)
        Process.unlink(root)
        {:ok, root}
      end)

    assert_receive {:waiting, writer}, 5_000
    assert Tay.status(name: @name).state == :recovering
    assert {:error, %{kind: :unavailable}} = Tay.get_job(Tay.JobID.new(), name: @name)
    send(writer, :continue)
    {:ok, root} = Task.await(task)
    assert Tay.status(name: @name).state == :ready
    H.stop(root)
  end

  for component <- [:writer, :guardian] do
    @component component
    test "#{component} death cannot restart storage beneath old projections", %{path: path} do
      {:ok, root} = H.start(path, @name)
      s = :sys.get_state(H.engine(root))
      Process.exit(Map.fetch!(s, @component), :kill)
      assert H.eventually(fn -> Tay.status(name: @name).state in [:failed, :unavailable] end)
      assert H.eventually(fn -> :ets.info(s.projection.jobs) == :undefined end)
      H.stop(root)
      {:ok, root} = H.restart(path, @name)
      refute :sys.get_state(H.engine(root)).generation == s.generation
      H.stop(root)
    end
  end

  test "old-generation permit cannot target a new owner; invalid input carries no arbitrary terms",
       %{path: path} do
    {:ok, root} = H.start(path, @name)
    {:ok, old} = Admission.metadata(@name)
    H.stop(root)
    {:ok, root} = H.restart(path, @name)
    before = R.snapshot(path)
    assert {:error, _} = Admission.request(@name, old, :stale_body, 256, :insert, "id", 20)
    {:ok, job} = EngineWorker.new(%{})

    assert {:error, %{kind: :invalid}} =
             Tay.insert(%{job | worker: %{secret: String.duplicate("x", 100_000)}}, name: @name)

    assert {:error, %{kind: :invalid, job_id: nil}} = Tay.insert(%{job | id: self()}, name: @name)
    assert {:error, _} = Tay.insert(%Tay.Job{}, name: @name)
    assert {:error, _} = Tay.insert(job, name: @name, timeout: :infinity)
    assert R.snapshot(path) == before
    H.stop(root)
  end

  test "secondary component exits preserve the first generation failure", %{path: path} do
    {:ok, root} = H.start(path, @name)
    Process.unlink(root)
    on_exit(fn -> H.stop(root) end)
    state = :sys.get_state(@name)

    send(@name, {Writer, state.writer, :poisoned})
    assert H.eventually(fn -> not Process.alive?(state.engine) end)

    for {ref, component} <- state.monitors, component in [:engine, :writer] do
      send(@name, {:DOWN, ref, :process, Map.fetch!(state, component), :killed})
    end

    assert %{state: :failed, reason: :writer_unavailable, failure_component: :writer} =
             Tay.status(name: @name)

    assert :ok = Tay.restart(name: @name)
    status = Tay.status(name: @name)
    assert status.state == :ready
    refute Map.has_key?(status, :failure_component)
    refute Map.has_key?(status, :failure_exit)
  end

  test "component death records its identity and bounded exit classification", %{path: path} do
    {:ok, root} = H.start(path, @name)
    Process.unlink(root)
    on_exit(fn -> H.stop(root) end)
    engine = H.engine(root)
    Process.exit(engine, :kill)

    assert H.eventually(fn ->
             match?(
               %{state: :failed, failure_component: :engine, failure_exit: :killed},
               Tay.status(name: @name)
             )
           end)
  end
end
