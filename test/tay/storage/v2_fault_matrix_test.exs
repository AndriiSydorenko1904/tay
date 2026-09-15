defmodule Tay.Storage.V2FaultMatrixTest do
  use ExUnit.Case, async: false

  alias Tay.Storage.{CRC32C, Native, Record, Segment}
  alias Tay.Storage.V2.{Authority, Codec, Publisher, Reclaimer, Reducer, V1Migration}
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
      {:ok, reopened} = reopen(path)

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
      :v2_rollback_marker_unlink,
      :v2_rollback_marker_sync,
      :v2_rollback_intent_unlink,
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
      {:ok, first} = reopen(path)
      assert :ok = Native.fault(first, site, 1, action)
      _ = V2Reader.reconcile_adoption(first)
      Native.shutdown(first)

      {:ok, second} = reopen(path)
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

      {:ok, reopened} = reopen(path)
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

      {:ok, reopened} = reopen(path)
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

  test "V2-to-V2 predecessor deletion resumes after each unlink and directory sync" do
    sites = [
      {:v2_reclaim_segment_unlink, 1},
      {:v2_reclaim_segment_unlink, 2},
      {:v2_reclaim_segment_sync, 1},
      {:v2_reclaim_segment_sync, 2},
      {:v2_reclaim_segments_unlink, 1},
      {:v2_reclaim_epoch_sync, 1},
      {:v2_reclaim_manifest_unlink, 1},
      {:v2_reclaim_manifest_sync, 1},
      {:v2_reclaim_epoch_unlink, 1},
      {:v2_reclaim_epochs_sync, 1}
    ]

    for {site, occurrence} <- sites, action <- [:syscall_error, :crash_after] do
      path = NativeHelpers.path()
      {_id, source} = one_job_source(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      assert {:ok, first} = Publisher.publish(native, source)
      assert {:ok, %{reclamation: :complete}} = Reclaimer.predecessor(native, first.recovered)

      second_source =
        Map.merge(source, %{
          epoch_id: first.epoch_id,
          current: first.recovered.current,
          jobs: first.recovered.candidate.jobs,
          frontier: first.recovered.next_sequence - 1
        })

      assert {:ok, second} = Publisher.publish(native, second_source)
      assert :ok = Native.fault(native, site, occurrence, action)
      assert {:ok, %{reclamation: :deferred}} = Reclaimer.predecessor(native, second.recovered)
      Native.shutdown(native)

      {:ok, reopened} = reopen(path)
      assert {:ok, recovered} = V2Reader.recover(reopened, Reducer.candidate())
      assert recovered.epoch_id == second.epoch_id
      assert recovered.candidate.jobs == second.recovered.candidate.jobs
      assert :ok = Native.enable_mutations(reopened)
      assert {:ok, %{reclamation: :complete}} = Reclaimer.predecessor(reopened, recovered)

      predecessor = "e-" <> Base.encode16(first.epoch_id, case: :lower)
      refute File.exists?(Path.join([path, "epochs", predecessor]))
      assert {:ok, again} = V2Reader.recover(reopened, Reducer.candidate())
      assert again.candidate.jobs == recovered.candidate.jobs
      assert :ok = Native.shutdown(reopened)
      File.rm_rf!(path)
    end
  end

  test "first-adoption legacy deletion resumes after each unlink and directory sync" do
    sites = [
      :v2_reclaim_segment_unlink,
      :v2_reclaim_segment_sync,
      :v2_reclaim_epoch_unlink,
      :v2_reclaim_epochs_sync,
      :v2_reclaim_adoption_unlink,
      :v2_reclaim_root_sync
    ]

    for site <- sites, action <- [:syscall_error, :crash_after] do
      path = NativeHelpers.path()
      {_id, source} = one_job_source(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      assert {:ok, published} = Publisher.publish(native, source)
      assert :ok = Native.fault(native, site, 1, action)
      assert {:ok, %{reclamation: :deferred}} = Reclaimer.predecessor(native, published.recovered)
      Native.shutdown(native)

      {:ok, reopened} = reopen(path)
      assert {:ok, recovered} = V2Reader.recover(reopened, Reducer.candidate())
      assert recovered.candidate.jobs == published.recovered.candidate.jobs
      assert :ok = Native.enable_mutations(reopened)
      assert {:ok, %{reclamation: :complete}} = Reclaimer.predecessor(reopened, recovered)
      refute File.exists?(Path.join(path, "ADOPTION"))
      assert :ok = Native.shutdown(reopened)
      File.rm_rf!(path)
    end
  end

  test "candidate admission bounds actual bytes across empty, rotated and large-snapshot stores" do
    for {count, arg_bytes, target} <- [
          {0, 0, 67_108_864},
          {1, 0, 67_108_864},
          {20, 900_000, Segment.min_rotation_bytes()},
          {3, 900_000, Segment.min_rotation_bytes()}
        ] do
      path = NativeHelpers.path()
      RecoveryHelpers.store(path)
      jobs = generated_jobs(count, arg_bytes)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)

      source = %{
        store_id: store_id(path),
        epoch_id: nil,
        jobs: jobs,
        frontier: 0,
        rotation_target_bytes: target,
        candidate_limits: %{},
        value_limits: Tay.Event.Value.defaults()
      }

      assert {:ok, published} = Publisher.publish(native, source)
      actual_candidate_bytes = candidate_file_bytes(path, published.epoch_id)
      assert published.candidate_bytes == actual_candidate_bytes
      assert published.admitted_candidate_bytes >= actual_candidate_bytes
      assert map_size(published.recovered.candidate.jobs) == count
      if count == 20, do: assert(length(published.recovered.manifest.base_segments) > 1)
      assert :ok = Native.shutdown(native)
      File.rm_rf!(path)
    end
  end

  test "candidate-headroom refusal never deletes or edits its V1 source" do
    path = NativeHelpers.path()
    {_id, source} = one_job_source(path)
    before = RecoveryHelpers.snapshot(path)
    {:ok, native} = RecoveryHelpers.open(path)
    assert :ok = Native.enable_mutations(native)

    assert {:error, :candidate_limit} =
             Publisher.publish(native, Map.put(source, :max_candidate_bytes, 1))

    assert :ok = Native.shutdown(native)
    assert RecoveryHelpers.snapshot(path) == before
    File.rm_rf!(path)
  end

  test "expired deadline before candidate creation leaves the V1 authority untouched" do
    path = NativeHelpers.path()
    {_id, source} = one_job_source(path)
    before = RecoveryHelpers.snapshot(path)
    {:ok, native} = RecoveryHelpers.open(path)
    assert :ok = Native.enable_mutations(native)
    expired = %{native | deadline: System.monotonic_time(:millisecond) - 1}
    assert {:error, _} = Publisher.publish(expired, source)
    assert :ok = Native.shutdown(native)
    assert RecoveryHelpers.snapshot(path) == before
    File.rm_rf!(path)
  end

  test "Store-v2 recovery refuses damaged metadata, base, tail and unexpected topology without repair" do
    corruptions = [
      :marker,
      :current,
      :manifest,
      :base_digest,
      :tail_sequence,
      :tail_mutation,
      :epoch_extra,
      :segments_extra,
      :root_directory
    ]

    for corruption <- corruptions do
      path = NativeHelpers.path()
      {_id, source} = one_job_source(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      assert {:ok, published} = Publisher.publish(native, source)
      assert :ok = Native.shutdown(native)

      epoch = Path.join([path, "epochs", "e-" <> Base.encode16(published.epoch_id, case: :lower)])
      segments = Path.join(epoch, "segments")
      {:ok, base_name} = Segment.filename(1)
      {:ok, tail_name} = Segment.filename(2)

      case corruption do
        :marker ->
          flip_first_byte(Path.join(path, "STORE-V2"))

        :current ->
          flip_first_byte(Path.join(path, "CURRENT"))

        :manifest ->
          flip_first_byte(Path.join(epoch, "MANIFEST"))

        :base_digest ->
          flip_first_byte(Path.join(segments, base_name))

        :tail_sequence ->
          {:ok, wrong_header} =
            Segment.encode_header(%{id: 2, first_sequence: 3, store_id: source.store_id})

          File.write!(Path.join(segments, tail_name), wrong_header)

        :tail_mutation ->
          {:ok, frame} =
            Record.encode(%Record{
              sequence: 2,
              record_type: 8,
              payload_schema_version: 1,
              payload: <<0>>
            })

          File.write!(
            Path.join(segments, tail_name),
            File.read!(Path.join(segments, tail_name)) <> frame
          )

        :epoch_extra ->
          File.write!(Path.join(epoch, "EXTRA"), <<1>>)

        :segments_extra ->
          File.write!(Path.join(segments, "EXTRA"), <<1>>)

        :root_directory ->
          File.mkdir!(Path.join(path, "unexpected"))
      end

      before = RecoveryHelpers.snapshot(path)
      {:ok, reopened} = RecoveryHelpers.open(path)

      assert {:error, _} = V2Reader.recover(reopened, Reducer.candidate()),
             "accepted #{corruption}"

      assert :ok = Native.shutdown(reopened)
      assert RecoveryHelpers.snapshot(path) == before
      File.rm_rf!(path)
    end
  end

  test "validly checksummed but unordered or wrong-profile snapshots fail closed" do
    for mode <- [:unordered, :wrong_profile] do
      path = NativeHelpers.path()
      RecoveryHelpers.store(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)

      source = %{
        store_id: store_id(path),
        epoch_id: nil,
        jobs: generated_jobs(2, 0),
        frontier: 0,
        rotation_target_bytes: 67_108_864,
        candidate_limits: %{},
        value_limits: Tay.Event.Value.defaults()
      }

      assert {:ok, published} = Publisher.publish(native, source)
      assert :ok = Native.shutdown(native)
      epoch = Path.join([path, "epochs", "e-" <> Base.encode16(published.epoch_id, case: :lower)])
      jobs = published.recovered.candidate.jobs
      {:ok, first_payload} = Codec.encode_snapshot(jobs[<<1::128>>])
      {:ok, second_payload} = Codec.encode_snapshot(jobs[<<2::128>>])

      frames =
        case mode do
          :unordered -> [{7, second_payload}, {7, first_payload}]
          :wrong_profile -> [{8, <<0>>}, {7, first_payload}]
        end

      {:ok, header} =
        Segment.encode_header(%{id: 1, first_sequence: 1, store_id: source.store_id})

      records =
        Enum.with_index(frames, 1)
        |> Enum.map(fn {{type, payload}, sequence} ->
          {:ok, frame} =
            Record.encode(%Record{
              sequence: sequence,
              record_type: type,
              payload_schema_version: 1,
              payload: payload
            })

          frame
        end)
        |> IO.iodata_to_binary()

      body = header <> records

      {:ok, footer} =
        Segment.encode_footer(%{
          id: 1,
          first_sequence: 1,
          last_sequence: 2,
          count: 2,
          store_id: source.store_id,
          segment_crc: CRC32C.checksum(body)
        })

      base = body <> footer
      {:ok, base_name} = Segment.filename(1)
      File.write!(Path.join([epoch, "segments", base_name]), base)
      manifest = published.recovered.manifest
      [original] = manifest.base_segments
      replacement = %{original | bytes: byte_size(base), digest: :crypto.hash(:sha256, base)}

      {:ok, manifest_bytes} =
        Authority.encode_manifest(%{manifest | base_segments: [replacement]})

      File.write!(Path.join(epoch, "MANIFEST"), manifest_bytes)

      {:ok, current} =
        Authority.encode_current(%{
          store_id: source.store_id,
          epoch_id: published.epoch_id,
          manifest_digest: Authority.manifest_digest(manifest_bytes)
        })

      File.write!(Path.join(path, "CURRENT"), current)
      before = RecoveryHelpers.snapshot(path)
      {:ok, reopened} = RecoveryHelpers.open(path)

      expected = if mode == :unordered, do: :snapshot_order, else: :record_profile
      assert {:error, %{reason: ^expected}} = V2Reader.recover(reopened, Reducer.candidate())
      assert :ok = Native.shutdown(reopened)
      assert RecoveryHelpers.snapshot(path) == before
      File.rm_rf!(path)
    end
  end

  defp flip_first_byte(path) do
    <<first, rest::binary>> = File.read!(path)
    File.write!(path, <<Bitwise.bxor(first, 1), rest::binary>>)
  end

  defp reopen(path), do: RecoveryHelpers.after_release(fn -> RecoveryHelpers.open(path) end)

  defp generated_jobs(count, arg_bytes) do
    definition = %{
      "args" => %{"blob" => :binary.copy(<<42>>, arg_bytes)},
      "definition_version" => 1,
      "max_attempts" => 3,
      "queue_key" => "default",
      "retry_policy" => Tay.Event.V1.policy(),
      "scheduled_at" => nil,
      "timeout_ms" => 1_000,
      "worker_key" => "worker"
    }

    Enum.reduce(1..count//1, Reducer.candidate(), fn index, candidate ->
      {:ok, next} =
        Reducer.apply(candidate, %{
          job_id: <<index::128>>,
          kind: :inserted,
          expected_revision: 0,
          new_revision: 1,
          at: 100,
          body: %{
            "definition" => definition,
            "eligible_at" => 100,
            "availability_order" => index
          }
        })

      next
    end).jobs
  end

  defp candidate_file_bytes(path, epoch_id) do
    epoch = Path.join([path, "epochs", "e-" <> Base.encode16(epoch_id, case: :lower)])
    segments = Path.join(epoch, "segments")

    Enum.sum(
      Enum.map(File.ls!(segments), fn name -> File.stat!(Path.join(segments, name)).size end)
    ) +
      Enum.sum(
        Enum.map(
          [
            Path.join(epoch, "MANIFEST"),
            Path.join(path, "CURRENT"),
            Path.join(path, "STORE-V2"),
            Path.join(path, "ADOPTION")
          ],
          &File.stat!(&1).size
        )
      )
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
