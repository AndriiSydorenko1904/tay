defmodule Tay.Storage.V2VMCrashTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000

  alias Tay.Storage.{Native, Segment}
  alias Tay.Storage.V2.{Publisher, Reclaimer, Reducer}
  alias Tay.Storage.V2.Reader, as: V2Reader
  alias Tay.Test.{NativeHelpers, RecoveryHelpers}

  test "whole-VM SIGKILL at V2 publication boundaries retains exactly one authority" do
    for site <- [
          :v2_publish_epoch,
          :v2_epoch_parent_sync,
          :v2_adopt_v1,
          :v2_adoption_epochs_sync,
          :v2_publish_current,
          :v2_current_root_sync
        ] do
      path = NativeHelpers.path()
      RecoveryHelpers.store(path)

      {output, status} =
        NativeHelpers.child_elixir(publication_script(), [path, Atom.to_string(site)])

      assert status != 0, "VM survived #{site}: #{output}"
      assert output =~ "ARMED:#{site}", "VM did not reach #{site}: #{output}"
      refute output =~ "UNREACHED"

      {:ok, native} = RecoveryHelpers.after_release(fn -> RecoveryHelpers.open(path) end)
      assert :ok = V2Reader.reconcile_adoption(native)
      {:ok, root} = Native.list(native, :root)

      if Enum.any?(root, &(&1.name == "CURRENT")) do
        assert {:ok, %{candidate: %{jobs: %{}}}} = V2Reader.recover(native, Reducer.candidate())
      else
        assert {:ok, %{store: %{store_id: _}}} = Tay.Storage.Reader.preflight(native)
      end

      assert :ok = Native.shutdown(native)
      File.rm_rf!(path)
    end
  end

  test "whole-VM SIGKILL during V2-to-V2 cleanup resumes with B authoritative" do
    for site <- [
          :v2_reclaim_segment_unlink,
          :v2_reclaim_segment_sync,
          :v2_reclaim_manifest_unlink,
          :v2_reclaim_epoch_unlink
        ] do
      path = NativeHelpers.path()
      RecoveryHelpers.store(path)
      {:ok, native} = RecoveryHelpers.open(path)
      assert :ok = Native.enable_mutations(native)
      {:ok, store_id} = path |> Path.join("STORE") |> File.read!() |> Segment.decode_store()
      assert {:ok, first} = Publisher.publish(native, empty_source(store_id))
      assert {:ok, %{reclamation: :complete}} = Reclaimer.predecessor(native, first.recovered)
      assert :ok = Native.shutdown(native)

      {output, status} =
        NativeHelpers.child_elixir(reclamation_script(), [path, Atom.to_string(site)])

      assert status != 0, "VM survived #{site}: #{output}"
      assert output =~ "ARMED:#{site}", "VM did not reach #{site}: #{output}"
      refute output =~ "UNREACHED"

      {:ok, reopened} = RecoveryHelpers.after_release(fn -> RecoveryHelpers.open(path) end)
      assert {:ok, recovered} = V2Reader.recover(reopened, Reducer.candidate())
      assert recovered.epoch_id != first.epoch_id
      assert recovered.manifest.source_epoch_id == first.epoch_id
      assert recovered.candidate.jobs == %{}
      assert :ok = Native.enable_mutations(reopened)
      assert {:ok, %{reclamation: :complete}} = Reclaimer.predecessor(reopened, recovered)

      refute File.exists?(
               Path.join([path, "epochs", "e-" <> Base.encode16(first.epoch_id, case: :lower)])
             )

      assert :ok = Native.shutdown(reopened)
      File.rm_rf!(path)
    end
  end

  defp empty_source(store_id) do
    %{
      store_id: store_id,
      epoch_id: nil,
      jobs: %{},
      frontier: 0,
      rotation_target_bytes: 67_108_864,
      candidate_limits: %{},
      value_limits: Tay.Event.Value.defaults()
    }
  end

  defp prelude do
    """
    Code.prepend_path(#{inspect(Application.app_dir(:stream_data, "ebin"))})
    {:ok, _} = Application.ensure_all_started(:tay)
    [path, site] = System.argv()
    site = String.to_existing_atom(site)
    {:ok, native} = Tay.Storage.Native.open_existing(path, durability: :write, test_helper: true)
    """
  end

  defp publication_script do
    prelude() <>
      """
      :ok = Tay.Storage.Native.enable_mutations(native)
      {:ok, store_id} = path |> Path.join("STORE") |> File.read!() |> Tay.Storage.Segment.decode_store()
      :ok = Tay.Storage.Native.fault(native, site, 1, :vm_crash_after)
      IO.puts("ARMED:" <> Atom.to_string(site))
      Tay.Storage.V2.Publisher.publish(native, %{
        store_id: store_id, epoch_id: nil, jobs: %{}, frontier: 0,
        rotation_target_bytes: 67_108_864, candidate_limits: %{},
        value_limits: Tay.Event.Value.defaults()
      })
      IO.puts("UNREACHED")
      """
  end

  defp reclamation_script do
    prelude() <>
      """
      {:ok, recovered} = Tay.Storage.V2.Reader.recover(native, Tay.Storage.V2.Reducer.candidate())
      :ok = Tay.Storage.Native.enable_mutations(native)
      {:ok, second} = Tay.Storage.V2.Publisher.publish(native, %{
        store_id: recovered.store_id, epoch_id: recovered.epoch_id,
        current: recovered.current, jobs: recovered.candidate.jobs,
        frontier: recovered.next_sequence - 1,
        rotation_target_bytes: 67_108_864, candidate_limits: %{},
        value_limits: Tay.Event.Value.defaults()
      })
      :ok = Tay.Storage.Native.fault(native, site, 1, :vm_crash_after)
      IO.puts("ARMED:" <> Atom.to_string(site))
      Tay.Storage.V2.Reclaimer.predecessor(native, second.recovered)
      IO.puts("UNREACHED")
      """
  end
end
