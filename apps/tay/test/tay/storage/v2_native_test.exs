defmodule Tay.Storage.V2NativeTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.{Native, Segment, Writer}
  alias Tay.Storage.V2.{Authority, Codec, Publisher, Reclaimer, Reducer}
  alias Tay.Storage.V2.Reader, as: V2Reader
  import Tay.Test.RecoveryHelpers

  setup do
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    store(path)
    marker = File.read!(Path.join(path, "STORE-V2"))
    current = File.read!(Path.join(path, "CURRENT"))
    {:ok, store_id} = Authority.decode_marker(marker)
    {:ok, pointer} = Authority.decode_current(current)
    %{path: path, store_id: store_id, epoch_id: pointer.epoch_id, current: current}
  end

  test "native owner selects and recovers the initialized Store v2 epoch", %{path: path} do
    {:ok, native} = open(path)

    assert {:ok, %{epoch_id: epoch_id, candidate: %{jobs: jobs}, current: current}} =
             V2Reader.recover(native, Reducer.candidate())

    assert jobs == %{}
    assert byte_size(current) == 76
    assert {:ok, entries} = Native.list(native, :segments)
    assert length(entries) == 1
    assert :ok = Native.shutdown(native)
    refute File.exists?(Path.join(path, "segments"))
    assert File.dir?(Path.join([path, "epochs", "e-" <> Base.encode16(epoch_id, case: :lower)]))
  end

  test "streaming publisher replaces CURRENT and reclaims predecessors", %{
    path: path,
    store_id: store_id,
    epoch_id: epoch_id,
    current: current
  } do
    {:ok, native} = open(path)
    assert {:ok, recovered} = V2Reader.recover(native, Reducer.candidate())
    assert :ok = Native.enable_mutations(native)

    source = %{
      store_id: store_id,
      epoch_id: epoch_id,
      current: current,
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

    assert first.previous_epoch_id == recovered.epoch_id
    assert {:ok, %{reclamation: :complete}} = Reclaimer.predecessor(native, first.recovered)

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

  test "Writer replays and activates the selected V2 epoch under its existing lock", %{
    path: path,
    epoch_id: epoch_id
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
    assert status.summary.epoch_id == epoch_id
    assert {:ok, summary, candidate} = Writer.activate_recovered(writer, status.session_ref)
    assert summary.epoch_id == epoch_id
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
          "retry_policy" => Tay.Event.V2.policy(),
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

  test "sole Writer owner compacts an activated V2 store and fences old admission", %{
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
    assert {:ok, published} = publish_next(native)

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
    path: path
  } do
    {:ok, native} = open(path)
    assert {:ok, _} = publish_next(native)

    script =
      "case Tay.Storage.Native.open_existing(hd(System.argv()), durability: :write) do " <>
        "{:ok, n} -> IO.puts(\"acquired\"); Tay.Storage.Native.close(n); " <>
        "{:error, e} -> IO.puts(e.reason) end"

    assert {"store_busy\n", 0} = Tay.Test.NativeHelpers.child_elixir(script, [path])
    assert :ok = Native.shutdown(native)
    assert {"acquired\n", 0} = Tay.Test.NativeHelpers.child_elixir(script, [path])
  end

  test "V2 activation refuses an independently mutated frozen tail without repair", %{
    path: path
  } do
    {:ok, native} = open(path)
    assert {:ok, published} = publish_next(native)

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

  defp publish_next(native) do
    with {:ok, recovered} <- V2Reader.recover(native, Reducer.candidate()),
         :ok <- Native.enable_mutations(native) do
      Publisher.publish(native, %{
        store_id: recovered.store_id,
        epoch_id: recovered.epoch_id,
        current: recovered.current,
        jobs: recovered.candidate.jobs,
        frontier: recovered.next_sequence - 1,
        rotation_target_bytes: 67_108_864,
        candidate_limits: %{},
        value_limits: Tay.Event.Value.defaults()
      })
    end
  end
end
