defmodule Tay.Execution.OperationsFaultTest do
  use ExUnit.Case, async: false
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.NativeHelpers
  alias Tay.Storage.Writer
  @name __MODULE__
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    path = H.initialize(NativeHelpers.path())
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, options \\ []) do
    assert {:ok, root} = H.start(path, @name, options)
    Process.unlink(root)
    on_exit(fn -> H.stop(root) end)
    root
  end

  test "drain cannot reply through a stalled post-commit/pre-projection boundary", %{path: path} do
    owner = self()

    root =
      start(path,
        test_hook: fn
          {:execution, 4, :post_append} ->
            send(owner, {:finish_committed, self()})

            receive do
              :continue -> :ok
            end

          _ ->
            :ok
        end
      )

    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    drain = Task.async(fn -> Tay.drain(name: @name, timeout: 5_000) end)
    assert H.eventually(fn -> Tay.status(name: @name).state == :draining end)
    send(task, {:return, :ok})
    assert_receive {:finish_committed, engine}, 5_000
    assert H.engine(root) == engine
    assert Task.yield(drain, 30) == nil
    assert Tay.status(name: @name).state == :draining
    send(engine, :continue)
    assert :ok = Task.await(drain)
    assert {:ok, %{state: :completed}} = Tay.get_job(job.id, name: @name)
  end

  for action <- [:error, :short, :crash_after] do
    @action action
    test "pending drain plus finish #{@action} never claims successful shutdown", %{path: path} do
      root = start(path)
      {job, token} = H.job()
      assert {:ok, _} = Tay.insert(job, name: @name)
      {task, _} = H.await_entry(token)
      drain = Task.async(fn -> Tay.drain(name: @name, timeout: 150) end)
      assert H.eventually(fn -> Tay.status(name: @name).state == :draining end)
      state = :sys.get_state(H.engine(root))

      assert :ok =
               Writer.inject_fault(
                 state.writer,
                 :write,
                 1,
                 @action,
                 5,
                 if(@action == :short, do: 19, else: 0)
               )

      send(task, {:return, :ok})
      assert {:error, %Tay.Error{kind: :unknown_outcome}} = Task.await(drain)
      assert H.eventually(fn -> Tay.status(name: @name).state == :failed end)
      assert H.eventually(fn -> not Process.alive?(task) end)
      H.stop(root)
      evidence = R.snapshot(path)

      if @action == :short do
        assert {:error, _} = H.start(path, @name)
        assert R.snapshot(path) == evidence
      else
        root = start(path, test_execution: false)
        expected = if @action == :crash_after, do: :completed, else: :executing
        assert {:ok, %{state: ^expected}} = Tay.get_job(job.id, name: @name)
        H.stop(root)
        assert R.snapshot(path) == evidence
      end
    end
  end

  test "pause barrier crash is unknown, writes no event, and does not persist pause", %{
    path: path
  } do
    owner = self()

    root =
      start(path,
        start_paused: true,
        test_hook: fn
          {:operations, :resume_queue} ->
            send(owner, {:resumed, self()})

            receive do
              :continue -> :ok
            end

          _ ->
            :ok
        end
      )

    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    before = R.snapshot(path)
    caller = Task.async(fn -> Tay.resume_queue(:default, name: @name, timeout: 100) end)
    assert_receive {:resumed, engine}, 5_000
    Process.exit(engine, :kill)
    assert {:error, %Tay.Error{kind: :unknown_outcome}} = Task.await(caller)
    H.stop(root)
    assert R.snapshot(path) == before
    root = start(path)
    {task, _} = H.await_entry(token)
    send(task, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    H.stop(root)
  end

  test "lifecycle drain fences queued administration before its acknowledgement is consumed", %{
    path: path
  } do
    owner = self()

    root =
      start(path,
        start_paused: true,
        test_hook: fn
          {:operations, :drained} ->
            send(owner, {:drained_boundary, self()})

            receive do
              :continue -> :ok
            end

          _ ->
            :ok
        end
      )

    {job, _} = H.job()
    assert {:ok, view} = Tay.insert(job, name: @name)
    before = R.snapshot(path)
    stopping = Task.async(fn -> Tay.stop(name: @name, timeout: 5_000) end)
    assert_receive {:drained_boundary, engine}, 5_000

    cancel =
      Task.async(fn -> Tay.cancel(job.id, name: @name, expected_revision: view.revision) end)

    assert H.eventually(fn ->
             Enum.any?(:ets.tab2list(@name), fn
               {slot, _, _, :submitted, _} when is_integer(slot) -> true
               _ -> false
             end)
           end)

    guardian = Process.whereis(@name)
    :ok = :sys.suspend(guardian)

    try do
      send(engine, :continue)
      # Guardian owns the final reply so the submitted permit is released
      # before this error can become visible to the caller.
      assert Task.yield(cancel, 20) == nil
    after
      if Process.alive?(guardian), do: :sys.resume(guardian)
    end

    assert {:error, %Tay.Error{reason: :generation_stopping}} = Task.await(cancel)
    assert R.snapshot(path) == before
    assert :ok = Task.await(stopping)
    assert Tay.status(name: @name).state == :stopped
    assert R.snapshot(path) == before
    H.stop(root)
  end
end
