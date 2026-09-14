defmodule Tay.Storage.V2FaultMatrixTest do
  use ExUnit.Case, async: false

  alias Tay.Storage.{Native, Record, Segment}
  alias Tay.Storage.V2.{Publisher, Reducer, V1Migration}
  alias Tay.Storage.V2.Reader, as: V2Reader
  alias Tay.Test.{NativeHelpers, RecoveryHelpers}

  @faults [
    {:v2_begin, 1, :crash_before},
    {:v2_begin, 1, :crash_after},
    {:v2_epochs_root_sync, 1, :crash_before},
    {:v2_epochs_root_sync, 1, :crash_after},
    {:v2_candidate_parent_sync, 1, :crash_before},
    {:v2_candidate_parent_sync, 1, :crash_after},
    {:v2_candidate_directory_sync, 1, :crash_before},
    {:v2_candidate_directory_sync, 1, :crash_after},
    {:create_stage, 1, :crash_before},
    {:create_stage, 2, :crash_after},
    {:write, 1, :short},
    {:write, 2, :crash_after},
    {:write, 3, :crash_after},
    {:write, 4, :crash_after},
    {:write, 5, :crash_after},
    {:sync, 1, :crash_after},
    {:sync, 2, :crash_after},
    {:sync, 3, :crash_after},
    {:sync, 4, :crash_after},
    {:sync, 5, :crash_after},
    {:v2_publish_epoch, 1, :crash_before},
    {:v2_publish_epoch, 1, :crash_after},
    {:v2_epoch_segments_sync, 1, :crash_before},
    {:v2_epoch_segments_sync, 1, :crash_after},
    {:v2_epoch_directory_sync, 1, :crash_before},
    {:v2_epoch_directory_sync, 1, :crash_after},
    {:v2_epoch_parent_sync, 1, :crash_before},
    {:v2_epoch_parent_sync, 1, :crash_after},
    {:publish, 1, :crash_after},
    {:publish, 2, :crash_after},
    {:v2_adopt_v1, 1, :crash_before},
    {:v2_adopt_v1, 1, :crash_after},
    {:v2_adoption_root_sync, 1, :crash_before},
    {:v2_adoption_root_sync, 1, :crash_after},
    {:v2_adoption_epochs_sync, 1, :crash_before},
    {:v2_adoption_epochs_sync, 1, :crash_after},
    {:v2_publish_current, 1, :crash_before},
    {:v2_publish_current, 1, :crash_after},
    {:v2_current_root_sync, 1, :crash_before},
    {:v2_current_root_sync, 1, :crash_after},
    {:v2_publish_current, 1, :drop_reply}
  ]

  test "every first-adoption publication fault preserves one replayable authority" do
    for {operation, occurrence, action} <- @faults do
      path = NativeHelpers.path()
      RecoveryHelpers.store(path)
      {:ok, store_id} = path |> Path.join("STORE") |> File.read!() |> Segment.decode_store()

      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      native = %{native | timeout: 200}
      assert :ok = Native.fault(native, operation, occurrence, action)

      _ =
        Publisher.publish(native, %{
          store_id: store_id,
          epoch_id: nil,
          jobs: %{},
          frontier: 0,
          rotation_target_bytes: 67_108_864,
          candidate_limits: %{},
          value_limits: Tay.Event.Value.defaults()
        })

      Native.shutdown(native)
      {:ok, reopened} = RecoveryHelpers.open(path)

      assert :ok = V2Reader.reconcile_adoption(reopened),
             "adoption rollback failed for #{inspect({operation, occurrence, action})}"

      {:ok, root} = Native.list(reopened, :root)

      if Enum.any?(root, &(&1.name == "CURRENT")) do
        assert {:ok, %{store_id: ^store_id, candidate: %{jobs: %{}}}} =
                 V2Reader.recover(reopened, Reducer.candidate())

        refute File.exists?(Path.join(path, "segments"))
      else
        assert {:ok, %{store: %{store_id: ^store_id}}} =
                 Tay.Storage.Reader.preflight(reopened)

        assert File.dir?(Path.join(path, "segments"))
      end

      assert :ok = Native.shutdown(reopened)
      File.rm_rf!(path)
    end
  end

  test "rollback itself resumes safely across every internal directory sync" do
    sites = [
      :v2_restore_epochs_sync,
      :v2_restore_root_sync,
      :v2_rollback_marker_sync,
      :v2_rollback_intent_sync
    ]

    for site <- sites, action <- [:crash_before, :crash_after] do
      path = NativeHelpers.path()
      RecoveryHelpers.store(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      assert :ok = Native.fault(native, :publish, 2, :crash_after)

      _ =
        Publisher.publish(native, %{
          store_id: store_id(path),
          epoch_id: nil,
          jobs: %{},
          frontier: 0,
          rotation_target_bytes: 67_108_864,
          candidate_limits: %{},
          value_limits: Tay.Event.Value.defaults()
        })

      Native.shutdown(native)
      {:ok, first} = RecoveryHelpers.open(path)
      assert :ok = Native.fault(first, site, 1, action)
      _ = V2Reader.reconcile_adoption(first)
      Native.shutdown(first)

      {:ok, second} = RecoveryHelpers.open(path)
      assert :ok = V2Reader.reconcile_adoption(second)
      assert {:ok, %{store: %{store_id: id}}} = Tay.Storage.Reader.preflight(second)
      assert id == store_id(path)
      assert :ok = Native.shutdown(second)
      File.rm_rf!(path)
    end
  end

  test "sealed-base write, footer and tail faults never publish a partial job" do
    for {operation, occurrence, action} <- [
          {:write, 1, :short},
          {:write, 2, :short},
          {:write, 3, :short},
          {:write, 1, :crash_after},
          {:write, 2, :crash_after},
          {:write, 3, :crash_after},
          {:write, 4, :crash_after},
          {:write, 5, :crash_after},
          {:sync, 1, :crash_before},
          {:sync, 1, :crash_after},
          {:sync, 2, :crash_after},
          {:sync, 3, :crash_after},
          {:close_write, 1, :crash_after},
          {:sync_dir, 1, :crash_after},
          {:sync_dir, 2, :crash_after},
          {:v2_publish_epoch, 1, :crash_after},
          {:v2_publish_current, 1, :crash_after}
        ] do
      path = NativeHelpers.path()
      {id, source} = one_job_source(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      assert :ok = Native.fault(native, operation, occurrence, action)
      _ = Publisher.publish(native, source)
      Native.shutdown(native)

      {:ok, reopened} = RecoveryHelpers.open(path)
      assert :ok = V2Reader.reconcile_adoption(reopened)
      {:ok, root} = Native.list(reopened, :root)

      if Enum.any?(root, &(&1.name == "CURRENT")) do
        assert {:ok, %{candidate: %{jobs: %{^id => job}}}} =
                 V2Reader.recover(reopened, Reducer.candidate())

        assert job.revision == 1
      else
        assert {:ok, %{store: %{next_sequence: 2}}} =
                 Tay.Storage.Reader.preflight(reopened)
      end

      assert :ok = Native.shutdown(reopened)
      File.rm_rf!(path)
    end
  end

  test "ENOSPC at base, tail, manifest and pointer sync preserves one authority" do
    for {operation, occurrence} <-
          Enum.map(1..5, &{:write, &1}) ++
            Enum.map(1..3, &{:sync, &1}) ++
            [{:v2_current_root_sync, 1}] do
      path = NativeHelpers.path()
      {_id, source} = one_job_source(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      assert :ok = Native.fault(native, operation, occurrence, :syscall_error, 28)
      _ = Publisher.publish(native, source)
      Native.shutdown(native)

      {:ok, reopened} = RecoveryHelpers.open(path)
      assert :ok = V2Reader.reconcile_adoption(reopened)
      {:ok, root} = Native.list(reopened, :root)

      if Enum.any?(root, &(&1.name == "CURRENT")) do
        assert {:ok, %{candidate: %{jobs: jobs}}} =
                 V2Reader.recover(reopened, Reducer.candidate())

        assert map_size(jobs) == 1
      else
        assert {:ok, %{store: %{next_sequence: 2}}} =
                 Tay.Storage.Reader.preflight(reopened)
      end

      assert :ok = Native.shutdown(reopened)
      File.rm_rf!(path)
    end
  end

  defp one_job_source(path) do
    id = <<9::128>>

    event = %Tay.Event{
      record_type: 1,
      data: %{
        "at" => 100,
        "expected_revision" => 0,
        "job_id" => id,
        "definition" => %{
          "args" => %{"value" => 1},
          "definition_version" => 1,
          "max_attempts" => 3,
          "queue_key" => "default",
          "retry_policy" => Tay.Event.V1.policy(),
          "scheduled_at" => nil,
          "timeout_ms" => 1_000,
          "worker_key" => "worker"
        },
        "eligible_at" => 100
      }
    }

    {:ok, {1, 1, payload}} = Tay.Event.encode(event)

    {:ok, bytes} =
      Record.encode(%Record{
        sequence: 1,
        record_type: 1,
        payload_schema_version: 1,
        payload: payload
      })

    RecoveryHelpers.store(path, [RecoveryHelpers.segment(1, 1, [bytes], true)])
    {:ok, migrated} = V1Migration.reduce(V1Migration.candidate(), event, %{sequence: 1})

    {id,
     %{
       store_id: store_id(path),
       epoch_id: nil,
       jobs: migrated.v2.jobs,
       frontier: 1,
       rotation_target_bytes: 67_108_864,
       candidate_limits: %{},
       value_limits: Tay.Event.Value.defaults()
     }}
  end

  defp store_id(path) do
    {:ok, id} = path |> Path.join("STORE") |> File.read!() |> Segment.decode_store()
    id
  end
end
