defmodule Tay.Engine.CompactionTest do
  use ExUnit.Case, async: false

  alias Tay.Test.{EngineHelpers, EngineWorker, NativeHelpers, RecoveryHelpers}

  @name __MODULE__

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    RecoveryHelpers.store(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "manual compaction drains, adopts V1, restarts V2 and scopes revisions", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)
    {:ok, intent} = EngineWorker.new(%{"before" => "compaction"})
    assert {:ok, original} = Tay.insert(intent, name: @name)
    assert {:tay_revision, _, _, _, physical_revision} = original.revision

    assert {:ok, stats} = Tay.compact(name: @name, timeout: 60_000)
    assert stats.epoch_id == stats.recovered.epoch_id
    assert stats.reclamation == :complete
    assert stats.reclaimed_bytes > 0
    refute File.exists?(Path.join(path, "ADOPTION"))
    assert Tay.status(name: @name).state == :ready
    assert {:ok, rewritten} = Tay.get_job(original.id, name: @name)
    assert {:tay_revision_v2, _, epoch_id, _, _, logical_revision} = rewritten.revision
    assert epoch_id == stats.epoch_id
    assert logical_revision == 1
    assert physical_revision == 1

    assert {:error, %{kind: :conflict}} =
             Tay.cancel(original.id, name: @name, expected_revision: original.revision)

    {:ok, after_intent} = EngineWorker.new(%{"after" => "compaction"})
    assert {:ok, after_job} = Tay.insert(after_intent, name: @name)
    assert {:tay_revision_v2, _, ^epoch_id, _, _, 1} = after_job.revision

    assert {:ok, second} = Tay.compact(name: @name, timeout: 60_000)
    assert second.epoch_id != epoch_id
    assert second.previous_epoch_id == epoch_id
    assert second.reclamation == :complete
    assert second.reclaimed_bytes > 0

    refute File.exists?(
             Path.join([path, "epochs", "e-" <> Base.encode16(epoch_id, case: :lower)])
           )

    assert {:ok, after_rewrite} = Tay.get_job(after_job.id, name: @name)
    assert {:tay_revision_v2, _, second_id, _, _, 1} = after_rewrite.revision
    assert second_id == second.epoch_id
    EngineHelpers.stop(root)

    {:ok, restarted} = EngineHelpers.restart(path, @name)

    assert {:ok, %{revision: {:tay_revision_v2, _, ^second_id, _, _, 1}}} =
             Tay.get_job(after_job.id, name: @name)

    EngineHelpers.stop(restarted)
  end

  test "lost CURRENT reply reconciles by the validated new pointer", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name, storage_timeout: 2_000)
    writer = :sys.get_state(@name).writer
    assert :ok = Tay.Storage.Writer.inject_fault(writer, :v2_publish_current, 1, :drop_reply)

    engine = :sys.get_state(@name).engine
    monitor = Process.monitor(engine)
    writer_monitor = Process.monitor(writer)
    result = Tay.compact(name: @name, timeout: 60_000)

    unless match?({:ok, _}, result) do
      receive do
        {:DOWN, ^monitor, :process, ^engine, reason} ->
          writer_exit =
            receive do
              {:DOWN, ^writer_monitor, :process, ^writer, writer_reason} -> writer_reason
            after
              1_000 -> :live
            end

          flunk(
            "lost-reply result #{inspect(result)}; Engine exit #{inspect(reason)}; " <>
              "Writer exit #{inspect(writer_exit)}; lifecycle #{inspect(Tay.status(name: @name))}"
          )
      after
        1_000 -> flunk("lost-reply result #{inspect(result)}; Engine remains live")
      end
    end

    Process.demonitor(monitor, [:flush])
    Process.demonitor(writer_monitor, [:flush])
    assert {:ok, stats} = result
    assert stats.publication_reconciled
    assert Tay.status(name: @name).state == :ready
    assert {:ok, second} = Tay.compact(name: @name, timeout: 60_000)
    assert second.previous_epoch_id == stats.epoch_id
    EngineHelpers.stop(root)
  end

  test "closed failed acquisition Ports cannot revoke the sole Writer", %{path: path} do
    hook = fn
      :recovery_promoted, _ ->
        assert {:error, %{reason: "store_busy"}} =
                 Tay.Storage.Native.open_existing(path, durability: :write, test_helper: true)

        :ok

      _, _ ->
        :ok
    end

    {:ok, root} = EngineHelpers.start(path, @name, writer_hook: hook)
    assert {:ok, intent} = EngineWorker.new(%{"closed_probe" => true})
    assert {:ok, _} = Tay.insert(intent, name: @name)
    assert {:ok, before} = Tay.get_job(intent.id, name: @name)
    assert {:ok, _} = Tay.compact(name: @name, timeout: 60_000)
    assert {:ok, after_compaction} = Tay.get_job(intent.id, name: @name)
    assert after_compaction.state == before.state
    assert after_compaction.definition == before.definition
    assert Tay.status(name: @name).state == :ready
    EngineHelpers.stop(root)
  end

  test "reclamation failure never rolls back CURRENT and startup resumes cleanup", %{path: path} do
    {:ok, root} = EngineHelpers.start(path, @name)
    writer = :sys.get_state(@name).writer
    assert :ok = Tay.Storage.Writer.inject_fault(writer, :v2_reclaim, 1, :error)

    assert {:ok, stats} = Tay.compact(name: @name, timeout: 60_000)
    assert stats.reclamation == :deferred
    assert stats.reclaimed_bytes == 0
    assert Tay.status(name: @name).state == :ready
    refute File.exists?(Path.join(path, "ADOPTION"))

    {:ok, intent} = EngineWorker.new(%{"after_cleanup" => true})

    assert {:ok, %{revision: {:tay_revision_v2, _, _, _, _, 1}}} =
             Tay.insert(intent, name: @name)

    EngineHelpers.stop(root)
  end

  test "manual compaction reconstructs a realistic many-segment V1 source", %{path: path} do
    count = 300

    segments =
      for sequence <- 1..count do
        event =
          Tay.Test.EventHelpers.inserted(
            Tay.Test.EventHelpers.definition(),
            0,
            Tay.Test.EventHelpers.id(sequence)
          )

        {:ok, {1, 1, payload}} = Tay.Event.encode(event)

        {:ok, frame} =
          Tay.Storage.Record.encode(%Tay.Storage.Record{
            record_type: 1,
            payload_schema_version: 1,
            payload: payload,
            sequence: sequence
          })

        RecoveryHelpers.segment(sequence, sequence, [frame], sequence < count)
      end

    RecoveryHelpers.store(path, segments)
    {:ok, root} = EngineHelpers.start(path, @name, workers: %{})
    assert Tay.status(name: @name).jobs == count
    started = System.monotonic_time(:millisecond)
    assert {:ok, stats} = Tay.compact(name: @name, timeout: 120_000)
    total_pause = System.monotonic_time(:millisecond) - started

    IO.puts(
      "V2_COMPACTION_MANY_SEGMENTS " <>
        inspect(
          stats
          |> Map.take([
            :source_bytes,
            :candidate_bytes,
            :admitted_candidate_bytes,
            :pause_ms,
            :peak_writer_process_bytes,
            :reclaimed_bytes
          ])
          |> Map.merge(%{segments: count, manual_call_ms: total_pause})
        )
    )

    assert length(stats.recovered.manifest.source_segments) == count
    assert stats.admitted_candidate_bytes >= stats.candidate_bytes
    assert stats.reclaimed_bytes == stats.source_bytes
    assert Tay.status(name: @name).jobs == count
    EngineHelpers.stop(root)

    {:ok, restarted} = EngineHelpers.restart(path, @name, workers: %{})
    assert Tay.status(name: @name).jobs == count
    EngineHelpers.stop(restarted)
  end

  test "compaction closes ordinary admission while its execution drain is in progress", %{
    path: path
  } do
    owner = self()

    hook = fn
      {:operations, :draining} ->
        send(owner, {:compaction_draining, self()})

        receive do
          :continue_compaction -> :ok
        end

      _ ->
        :ok
    end

    {:ok, root} = EngineHelpers.start(path, @name, test_hook: hook)
    task = Task.async(fn -> Tay.compact(name: @name, timeout: 60_000) end)
    assert_receive {:compaction_draining, engine}, 5_000
    {:ok, intent} = EngineWorker.new(%{"should_not_commit" => true})
    assert {:error, %Tay.Error{kind: :unavailable}} = Tay.insert(intent, name: @name)
    send(engine, :continue_compaction)
    assert {:ok, _} = Task.await(task, 60_000)
    assert Tay.status(name: @name).jobs == 0
    EngineHelpers.stop(root)
  end

  test "pre-publication disk-admission failure recovers the old authority and resumes", %{
    path: path
  } do
    {:ok, root} = EngineHelpers.start(path, @name)
    writer = :sys.get_state(@name).writer
    assert :ok = Tay.Storage.Writer.inject_fault(writer, :v2_space, 1, :error, 28)

    assert {:error, %Tay.Error{kind: :unknown_outcome}} =
             Tay.compact(name: @name, timeout: 60_000)

    assert Tay.status(name: @name).state == :ready
    assert File.dir?(Path.join(path, "segments"))
    refute File.exists?(Path.join(path, "CURRENT"))
    {:ok, intent} = EngineWorker.new(%{"after_headroom_refusal" => true})
    assert {:ok, _} = Tay.insert(intent, name: @name)
    EngineHelpers.stop(root)
  end
end
