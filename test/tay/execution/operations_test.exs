defmodule Tay.Execution.OperationsTest do
  use ExUnit.Case, async: false
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.NativeHelpers
  @name __MODULE__
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    H.install()
    path = NativeHelpers.path()
    H.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, opts \\ []) do
    assert {:ok, root} = H.start(path, @name, opts)
    Process.unlink(root)
    on_exit(fn -> H.stop(root) end)
    root
  end

  test "pause barrier stops new claims, not active tasks; startup pause is volatile", %{
    path: path
  } do
    root = start(path, start_paused: true)
    {first, token} = H.job()
    assert {:ok, _} = Tay.insert(first, name: @name)
    assert :ok = Tay.pause_queue(:default, name: @name)
    assert H.entries(token) == 0
    assert :ok = Tay.resume_queue("default", name: @name)
    {task, _} = H.await_entry(token)
    assert :ok = Tay.pause_queue(:default, name: @name)
    {next, next_token} = H.job()
    assert {:ok, _} = Tay.insert(next, name: @name)
    send(task, {:return, :ok})
    H.await_job(@name, first.id, :completed)
    assert H.eventually(fn -> Tay.status(name: @name).running_executions == 0 end)
    assert H.entries(next_token) == 0
    H.stop(root)
    start(path)
    {task, _} = H.await_entry(next_token)
    send(task, {:return, :ok})
    H.await_job(@name, next.id, :completed)
  end

  test "drain waits for durable outcome AND task death, keeps queued work and reconciliation", %{
    path: path
  } do
    owner = self()
    root = start(path, test_terminate: fn task -> send(owner, {:deferred_kill, task}) end)
    {job, token} = H.job()
    {queued, queued_token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    assert {:ok, _} = Tay.insert(queued, name: @name)
    drain = Task.async(fn -> Tay.drain(name: @name, timeout: 5_000) end)
    assert H.eventually(fn -> Tay.status(name: @name).state == :draining end)
    {rejected, _} = H.job()
    assert {:error, %Tay.Error{reason: :draining}} = Tay.insert(rejected, name: @name)
    assert {:ok, %{id: id}} = Tay.insert(queued, name: @name)
    assert id == queued.id
    # Timeout settlement is committed before the injected delayed termination.
    H.tick(root, H.clock(:wall), 30_000)
    {relay, entry} = H.runtime_entry(root, job.id)
    send(relay, {:timeout, entry.ticket})
    assert_receive {:deferred_kill, ^task}, 5_000
    assert Process.alive?(task)
    assert Task.yield(drain, 20) == nil
    assert Tay.status(name: @name).state == :draining
    Process.exit(task, :kill)
    assert :ok = Task.await(drain)
    assert H.eventually(fn -> Tay.status(name: @name).state == :drained end)
    assert H.entries(queued_token) == 0
    assert :ok = Tay.resume_queue(:default, name: @name)
    assert {:ok, %{state: :available}} = Tay.get_job(queued.id, name: @name)
    assert H.entries(queued_token) == 0
    assert :ok = Tay.drain(name: @name)
  end

  test "drain timeout remains draining and does not free active credit", %{path: path} do
    start(path)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    assert {:error, %Tay.Error{kind: kind}} = Tay.drain(name: @name, timeout: 20)
    assert kind in [:timeout, :unknown_outcome]
    assert H.eventually(fn -> Tay.status(name: @name).state == :draining end)
    assert Tay.status(name: @name).queue_slots_used == %{"default" => 1}
    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
    send(task, {:return, :ok})
    assert H.eventually(fn -> Tay.status(name: @name).state == :drained end)
  end

  test "invalid control options and unknown queues do not affect generation", %{path: path} do
    start(path)
    assert {:error, %Tay.Error{kind: :invalid}} = Tay.pause_queue(<<255>>, name: @name)
    assert {:error, %Tay.Error{reason: :unknown_queue}} = Tay.pause_queue(:absent, name: @name)
    assert {:error, %Tay.Error{kind: :invalid}} = Tay.drain(name: @name, force: true)
    assert Tay.status(name: @name).state == :ready
  end

  test "history accounting is exact and active outcome reserve survives admission exhaustion", %{
    path: path
  } do
    root = start(path, max_history_bytes: 2_500)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    assert H.eventually(fn -> Tay.status(name: @name).reserved_outcome_bytes > 0 end)

    results =
      for _ <- 1..10 do
        {next, _} = H.job(scheduled_at: 2_000_000)
        Tay.insert(next, name: @name)
      end

    assert Enum.any?(
             results,
             &match?({:error, %Tay.Error{kind: :capacity, reason: :max_history_bytes}}, &1)
           )

    send(task, {:return, :ok})
    H.await_job(@name, job.id, :completed)
    assert :ok = Tay.drain(name: @name)
    snapshot = Tay.status(name: @name)
    assert snapshot.reserved_outcome_bytes == 0
    assert snapshot.canonical_history_bytes <= 2_500
    assert snapshot.segment_count == 1
    assert snapshot.compaction_terminal_retention == {:hours, 24}
    H.stop(root)
    # Canonical filenames are resolved through the frozen segment parser.
    files =
      File.ls!(Path.join(path, "segments"))
      |> Enum.filter(&match?({:ok, _}, Tay.Storage.Segment.filename_id(&1)))

    assert snapshot.canonical_history_bytes ==
             Enum.sum(Enum.map(files, &File.stat!(Path.join([path, "segments", &1])).size))

    definitions =
      H.history(path)
      |> Enum.filter(&(&1.event.record_type == 1))
      |> Enum.map(fn row ->
        {:ok, bytes} = Tay.Event.Value.encode(row.event.data["definition"])
        byte_size(bytes)
      end)

    assert snapshot.retained_definition_bytes == Enum.sum(definitions)
  end

  test "segment admission reserves an outcome coordinate before starting", %{path: path} do
    start(path, max_segments: 1)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    assert :ok = Tay.pause_queue(:default, name: @name)
    assert {:ok, %{state: :available}} = Tay.get_job(job.id, name: @name)
    assert H.entries(token) == 0
    assert :ok = Tay.drain(name: @name)
  end

  test "concurrent drains occupy bounded permits until timeout, but outcomes still settle", %{
    path: path
  } do
    start(path, client_slots: 2)
    {job, token} = H.job()
    assert {:ok, _} = Tay.insert(job, name: @name)
    {task, _} = H.await_entry(token)
    drains = for _ <- 1..2, do: Task.async(fn -> Tay.drain(name: @name, timeout: 500) end)
    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 2 end)

    assert {:error, %Tay.Error{kind: :capacity, reason: :client_slots}} =
             Tay.pause_queue(:default, name: @name)

    send(task, {:return, :ok})
    for drain <- drains, do: assert(:ok = Task.await(drain))
    assert H.eventually(fn -> Tay.status(name: @name).state == :drained end)
    assert {:ok, %{state: :completed}} = Tay.get_job(job.id, name: @name)
  end

  test "Event v1 maximum fixed-width finish and cancel frames fit the reserved envelope" do
    common = %{
      "job_id" => <<1::128>>,
      "expected_revision" => 18_446_744_073_709_551_615,
      "at" => 9_223_372_036_854_775_807
    }

    outcomes =
      [{0, 0, nil}] ++
        for(
          code <- [1, 2, 3, 4, 6],
          disposition <- [1, 2],
          do: {1, disposition, %{"code" => code, "version" => 1}}
        ) ++
        [
          {2, 1, %{"code" => 5, "version" => 1}},
          {2, 2, %{"code" => 5, "version" => 1}},
          {3, 1, %{"code" => 7, "version" => 1}}
        ]

    events =
      Enum.map(outcomes, fn {outcome, disposition, diagnostic} ->
        %Tay.Event{
          record_type: 4,
          data:
            Map.merge(common, %{
              "execution_token" => 18_446_744_073_709_551_615,
              "outcome" => outcome,
              "disposition" => disposition,
              "diagnostic" => diagnostic,
              "next_attempt" => if(disposition == 1, do: 65_535, else: nil),
              "next_due_at" => if(disposition == 1, do: 9_223_372_036_854_775_807, else: nil)
            })
        }
      end) ++
        Enum.map([nil, 18_446_744_073_709_551_615], fn token ->
          %Tay.Event{record_type: 5, data: Map.put(common, "execution_token", token)}
        end)

    for event <- events do
      assert {:ok, {_, 1, payload}} = Tay.Event.encode(event)
      assert byte_size(payload) + 28 <= 1_024
    end
  end
end
