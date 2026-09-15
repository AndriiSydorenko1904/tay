defmodule Tay.Storage.V2NativeTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.{Native, Reader, Segment, Writer}
  alias Tay.Storage.V2.{Authority, Codec, Epoch, Publisher, Reducer}
  alias Tay.Storage.V2.Reader, as: V2Reader
  import Tay.Test.RecoveryHelpers

  @candidate <<1::128>>
  @epoch <<2::128>>
  @legacy <<3::128>>
  @marker_stage ".tay-v2-marker-00000000000000000000000000000004.tmp"
  @current_stage ".tay-current-00000000000000000000000000000005.tmp"
  @adoption_stage ".tay-adoption-00000000000000000000000000000006.tmp"

  setup do
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    store(path)
    {:ok, store_id} = path |> Path.join("STORE") |> File.read!() |> Segment.decode_store()
    %{path: path, store_id: store_id}
  end

  test "native owner publishes a complete empty epoch and old binary topology fails closed", %{
    path: path,
    store_id: store_id
  } do
    {:ok, native} = open(path)
    assert :ok = Native.enable_mutations(native)
    assert {:ok, free} = Native.v2_space(native)
    assert free > 0
    assert :ok = Native.v2_begin(native, @candidate)

    {:ok, epoch} = Epoch.build(%{}, store_id)
    {:ok, name} = Segment.filename(1)
    {:ok, _} = Native.create_stage(native, :candidate_segments, name)
    assert {:ok, %{written: 44}} = Native.write(native, 0, epoch.tail)
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert :ok = Native.sync_dir(native, :candidate_segments)

    manifest = %{
      store_id: store_id,
      epoch_id: @epoch,
      source_epoch_id: nil,
      source_frontier: 0,
      captured_at: 0,
      terminal_retention: :infinity,
      source_segments: [],
      base_segments: [],
      tail_segment_id: 1,
      tail_first_sequence: 1
    }

    {:ok, manifest_bytes} = Authority.encode_manifest(manifest)
    {:ok, _} = Native.create_stage(native, :candidate, "MANIFEST")
    assert {:ok, _} = Native.write(native, 0, manifest_bytes)
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert :ok = Native.sync_dir(native, :candidate)

    assert {:ok, %{candidate: %{jobs: %{}}, manifest_bytes: ^manifest_bytes}} =
             V2Reader.recover_candidate(native, Reducer.candidate(), manifest)

    assert :ok = Native.v2_publish_epoch(native, @epoch)

    {:ok, intent} = Authority.encode_adoption(@legacy)
    {:ok, adoption_identity} = Native.create_stage(native, :root, @adoption_stage)
    assert {:ok, _} = Native.write(native, 0, intent)
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert :ok = Native.publish(native, :root, @adoption_stage, "ADOPTION", adoption_identity)
    assert :ok = Native.sync_dir(native, :root)
    assert :ok = Native.v2_adopt_v1(native, @legacy)
    {:ok, marker} = Authority.encode_marker(store_id)
    {:ok, marker_identity} = Native.create_stage(native, :root, @marker_stage)
    assert {:ok, _} = Native.write(native, 0, marker)
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert :ok = Native.publish(native, :root, @marker_stage, "STORE-V2", marker_identity)
    assert :ok = Native.sync_dir(native, :root)

    {:ok, current} =
      Authority.encode_current(%{
        store_id: store_id,
        epoch_id: @epoch,
        manifest_digest: Authority.manifest_digest(manifest_bytes)
      })

    {:ok, current_identity} = Native.create_stage(native, :root, @current_stage)
    assert {:ok, _} = Native.write(native, 0, current)
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert :ok = Native.v2_publish_current(native, @current_stage, current_identity, nil)
    assert :ok = Native.v2_select(native, @epoch)
    assert {:ok, entries} = Native.list(native, :segments)
    assert Enum.map(entries, & &1.name) == [name]
    assert :ok = Native.shutdown(native)

    {:ok, reopened} = open(path)
    assert {:error, %{reason: :store_v2_requires_v2_recovery}} = Reader.preflight(reopened)

    assert {:ok, %{epoch_id: @epoch, candidate: %{jobs: jobs}}} =
             V2Reader.recover(reopened, Reducer.candidate())

    assert jobs == %{}
    assert {:ok, _} = Native.open_read(reopened, :epoch, "MANIFEST")
    assert {:ok, ^manifest_bytes} = Native.read(reopened, 0, byte_size(manifest_bytes))
    assert :ok = Native.close_read(reopened)
    assert :ok = Native.enable_mutations(reopened)
    assert {:ok, _} = Native.open_read(reopened, :root, "CURRENT")
    assert {:ok, ^current} = Native.read(reopened, 0, byte_size(current))
    assert :ok = Native.close_read(reopened)
    assert :ok = Native.shutdown(reopened)

    refute File.exists?(Path.join(path, "segments"))

    assert File.dir?(
             Path.join([path, "epochs", "legacy-" <> Base.encode16(@legacy, case: :lower)])
           )
  end

  test "streaming publisher adopts V1 and then replaces CURRENT for a second epoch", %{
    path: path,
    store_id: store_id
  } do
    {:ok, native} = open(path)
    assert :ok = Native.enable_mutations(native)

    source = %{
      store_id: store_id,
      epoch_id: nil,
      jobs: %{},
      frontier: 0,
      rotation_target_bytes: 67_108_864,
      candidate_limits: %{},
      value_limits: Tay.Event.Value.defaults()
    }

    assert {:ok, first} = Publisher.publish(native, source)
    assert first.candidate_bytes > 0
    assert first.source_bytes > 0
    assert first.recovered.candidate.jobs == %{}

    assert {:ok, adoption_entry} = Native.open_read(native, :root, "ADOPTION")
    assert {:ok, intent} = Native.read(native, 0, adoption_entry.size)
    assert :ok = Native.close_read(native)
    assert {:ok, legacy_nonce} = Authority.decode_adoption(intent)
    legacy_name = "legacy-" <> Base.encode16(legacy_nonce, case: :lower)

    assert {:ok, reclaimed_v1} =
             Native.v2_reclaim(native, legacy_name, first.recovered.current, intent)

    assert reclaimed_v1 > 0
    refute File.exists?(Path.join([path, "epochs", legacy_name]))
    refute File.exists?(Path.join(path, "ADOPTION"))

    second_source =
      source
      |> Map.put(:epoch_id, first.epoch_id)
      |> Map.put(:current, first.recovered.current)

    assert {:ok, second} = Publisher.publish(native, second_source)
    assert second.epoch_id != first.epoch_id
    assert second.previous_epoch_id == first.epoch_id
    first_name = "e-" <> Base.encode16(first.epoch_id, case: :lower)

    assert {:ok, reclaimed_epoch} =
             Native.v2_reclaim(native, first_name, second.recovered.current)

    assert reclaimed_epoch > 0
    refute File.exists?(Path.join([path, "epochs", first_name]))
    assert :ok = Native.shutdown(native)

    {:ok, reopened} = open(path)

    assert {:ok, %{epoch_id: second_id, candidate: %{jobs: %{}}}} =
             V2Reader.recover(reopened, Reducer.candidate())

    assert second_id == second.epoch_id
    assert :ok = Native.shutdown(reopened)
  end

  test "pre-CURRENT adoption interruption restores the authoritative V1 source", %{
    path: path,
    store_id: store_id
  } do
    {:ok, native} = open(path)
    assert :ok = Native.enable_mutations(native)
    assert :ok = Native.v2_begin(native, @candidate)

    {:ok, intent} = Authority.encode_adoption(@legacy)
    {:ok, identity} = Native.create_stage(native, :root, @adoption_stage)
    assert {:ok, _} = Native.write(native, 0, intent)
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert :ok = Native.publish(native, :root, @adoption_stage, "ADOPTION", identity)
    assert :ok = Native.sync_dir(native, :root)
    assert :ok = Native.v2_adopt_v1(native, @legacy)

    {:ok, marker} = Authority.encode_marker(store_id)
    {:ok, marker_identity} = Native.create_stage(native, :root, @marker_stage)
    assert {:ok, _} = Native.write(native, 0, marker)
    assert :ok = Native.sync(native)
    assert :ok = Native.close_write(native)
    assert :ok = Native.publish(native, :root, @marker_stage, "STORE-V2", marker_identity)
    assert :ok = Native.sync_dir(native, :root)
    assert :ok = Native.shutdown(native)

    refute File.exists?(Path.join(path, "segments"))
    {:ok, reopened} = open(path)
    assert :ok = V2Reader.reconcile_adoption(reopened)
    assert {:ok, %{store: %{store_id: ^store_id}}} = Reader.preflight(reopened)
    assert :ok = Native.shutdown(reopened)
    assert File.dir?(Path.join(path, "segments"))
    refute File.exists?(Path.join(path, "ADOPTION"))
    refute File.exists?(Path.join(path, "STORE-V2"))
  end

  test "Writer replays and activates the selected V2 epoch under its existing lock", %{
    path: path,
    store_id: store_id
  } do
    {:ok, native} = open(path)
    assert :ok = Native.enable_mutations(native)

    assert {:ok, published} =
             Publisher.publish(native, %{
               store_id: store_id,
               epoch_id: nil,
               jobs: %{},
               frontier: 0,
               rotation_target_bytes: 67_108_864,
               candidate_limits: %{},
               value_limits: Tay.Event.Value.defaults()
             })

    assert :ok = Native.shutdown(native)

    spec = %{
      codec: Tay.Event,
      initial_acc: Tay.State.Transition.candidate(%{}, Tay.Event.Value.defaults()),
      reducer: &Tay.State.Transition.reduce/3,
      options: []
    }

    assert {:ok, writer} =
             Writer.start_recovered_link([data_dir: path, durability: :write], spec)

    status = Writer.status(writer)
    assert status.summary.epoch_id == published.epoch_id
    assert {:ok, summary, candidate} = Writer.activate_recovered(writer, status.session_ref)
    assert summary.epoch_id == published.epoch_id
    assert candidate.jobs == %{}
    assert Writer.status(writer).state == :ready

    job_id = <<9::128>>

    mutation = %{
      job_id: job_id,
      kind: :inserted,
      expected_revision: 0,
      new_revision: 1,
      at: 100,
      body: %{
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
        "eligible_at" => 100,
        "availability_order" => 1
      }
    }

    assert {:ok, payload} = Codec.encode_mutation(mutation)
    assert {:ok, %{sequence: 1}} = Writer.append(writer, summary.admission_ref, 8, 1, payload)
    assert :ok = GenServer.stop(writer)

    {:ok, reopened} = open(path)

    assert {:ok, %{candidate: %{jobs: %{^job_id => job}}}} =
             V2Reader.recover(reopened, Reducer.candidate())

    assert job.revision == 1
    assert job.availability_order == 1
    assert :ok = Native.shutdown(reopened)
  end

  test "sole Writer owner compacts an activated V1 store and fences old admission", %{
    path: path
  } do
    spec = %{
      codec: Tay.Event,
      initial_acc: Tay.State.Transition.candidate(%{}, Tay.Event.Value.defaults()),
      reducer: &Tay.State.Transition.reduce/3,
      options: []
    }

    assert {:ok, writer} =
             Writer.start_recovered_link([data_dir: path, durability: :write], spec)

    status = Writer.status(writer)

    assert {:ok, summary, %{jobs: %{}}} =
             Writer.activate_recovered(writer, status.session_ref)

    assert {:ok, stats} = Writer.compact(writer, summary.admission_ref)
    assert stats.recovered.epoch_id == stats.epoch_id

    assert {:error, :compaction_restart_required} =
             Writer.append(writer, summary.admission_ref, 8, 1, <<1>>)

    assert :ok = GenServer.stop(writer)
    {:ok, reopened} = open(path)
    assert {:ok, %{epoch_id: epoch_id}} = V2Reader.recover(reopened, Reducer.candidate())
    assert epoch_id == stats.epoch_id
    assert :ok = Native.shutdown(reopened)
  end

  test "Engine inserts into V2 tail with epoch-scoped public revisions", %{
    path: path,
    store_id: store_id
  } do
    {:ok, native} = open(path)
    assert :ok = Native.enable_mutations(native)

    assert {:ok, published} =
             Publisher.publish(native, %{
               store_id: store_id,
               epoch_id: nil,
               jobs: %{},
               frontier: 0,
               rotation_target_bytes: 67_108_864,
               candidate_limits: %{},
               value_limits: Tay.Event.Value.defaults()
             })

    assert :ok = Native.shutdown(native)
    name = :tay_v2_engine_native_test
    {:ok, root} = Tay.Test.EngineHelpers.start(path, name)
    {:ok, intent} = Tay.Test.EngineWorker.new(%{"v2" => true})
    assert {:ok, job} = Tay.insert(intent, name: name)

    assert {:tay_revision_v2, ^store_id, epoch_id, _, _, 1} = job.revision
    assert epoch_id == published.epoch_id
    assert {:ok, ^job} = Tay.get_job(job.id, name: name)
    Tay.Test.EngineHelpers.stop(root)

    {:ok, restarted} = Tay.Test.EngineHelpers.restart(path, name)
    assert {:ok, recovered} = Tay.get_job(job.id, name: name)
    assert {:tay_revision_v2, ^store_id, ^epoch_id, _, _, 1} = recovered.revision
    Tay.Test.EngineHelpers.stop(restarted)
  end

  test "independent BEAM cannot acquire the selected V2 epoch while its Writer owns the lock", %{
    path: path,
    store_id: store_id
  } do
    {:ok, native} = open(path)
    assert :ok = Native.enable_mutations(native)

    assert {:ok, _} =
             Publisher.publish(native, %{
               store_id: store_id,
               epoch_id: nil,
               jobs: %{},
               frontier: 0,
               rotation_target_bytes: 67_108_864,
               candidate_limits: %{},
               value_limits: Tay.Event.Value.defaults()
             })

    script =
      "case Tay.Storage.Native.open_existing(hd(System.argv()), durability: :write) do " <>
        "{:ok, n} -> IO.puts(\"acquired\"); Tay.Storage.Native.close(n); " <>
        "{:error, e} -> IO.puts(e.reason) end"

    assert {"store_busy\n", 0} = Tay.Test.NativeHelpers.child_elixir(script, [path])
    assert :ok = Native.shutdown(native)
    assert {"acquired\n", 0} = Tay.Test.NativeHelpers.child_elixir(script, [path])
  end

  test "V2 activation refuses an independently mutated frozen tail without repair", %{
    path: path,
    store_id: store_id
  } do
    {:ok, native} = open(path)
    assert :ok = Native.enable_mutations(native)

    assert {:ok, published} =
             Publisher.publish(native, %{
               store_id: store_id,
               epoch_id: nil,
               jobs: %{},
               frontier: 0,
               rotation_target_bytes: 67_108_864,
               candidate_limits: %{},
               value_limits: Tay.Event.Value.defaults()
             })

    assert :ok = Native.shutdown(native)
    {:ok, tail_name} = Segment.filename(1)

    tail =
      Path.join([
        path,
        "epochs",
        "e-" <> Base.encode16(published.epoch_id, case: :lower),
        "segments",
        tail_name
      ])

    hook = fn
      :recovery_revalidating, _native ->
        caller = self()

        spawn(fn ->
          File.write!(tail, File.read!(tail) <> <<0>>)
          send(caller, :tail_mutated)
        end)

        receive do
          :tail_mutated -> :ok
        after
          5_000 -> {:error, :mutation_timeout}
        end

      _, _ ->
        :ok
    end

    spec = %{
      codec: Tay.Event,
      initial_acc: Tay.State.Transition.candidate(%{}, Tay.Event.Value.defaults()),
      reducer: &Tay.State.Transition.reduce/3,
      options: []
    }

    assert {:ok, writer} =
             Writer.start_recovered_link(
               [data_dir: path, durability: :write, on_transition: hook],
               spec
             )

    status = Writer.status(writer)

    assert {:error, %{stage: :revalidation, action: :preserve_and_stop, mutation: :none}} =
             Writer.activate_recovered(writer, status.session_ref)

    assert binary_part(File.read!(tail), 44, 1) == <<0>>
    GenServer.stop(writer)
  end
end
