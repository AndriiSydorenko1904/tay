defmodule Tay.Engine.LargeRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag :large_recovery
  @moduletag timeout: 900_000
  @moduletag skip: System.get_env("TAY_LARGE_RECOVERY_TEST") != "1"
  alias Tay.Test.{NativeHelpers, EventHelpers}
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.EngineHelpers, as: H
  alias Tay.Storage.V2.Mutation

  test "10,000 production definitions rebuild, compact and recover bounded state" do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    R.store(path)

    try do
      R.write_v2_mutations(path, fn append ->
        for seq <- 1..10_000 do
          event = EventHelpers.inserted(EventHelpers.definition(), 0, EventHelpers.id(seq))
          {:ok, mutation} = Mutation.from_event(event, nil, 1)
          :ok = append.(mutation)
        end
      end)

      {:ok, root} = H.restart(path, __MODULE__, workers: %{})
      assert Tay.status(name: __MODULE__).jobs == 10_000
      assert Tay.status(name: __MODULE__).blocked_jobs == 10_000

      for seq <- [1, 5000, 10_000],
          do:
            assert(
              {:ok, %{state: :scheduled}} =
                Tay.get_job(Tay.JobID.encode(EventHelpers.id(seq)), name: __MODULE__)
            )

      assert {:ok, stats} = Tay.compact(name: __MODULE__, timeout: 900_000)
      assert stats.admitted_candidate_bytes >= stats.candidate_bytes
      assert stats.reclamation == :complete
      assert stats.reclaimed_bytes > 0
      assert Tay.status(name: __MODULE__).jobs == 10_000

      IO.puts(
        "V2_COMPACTION_10000 source=#{stats.source_bytes} candidate=#{stats.candidate_bytes} " <>
          "admitted=#{stats.admitted_candidate_bytes} pause_ms=#{stats.pause_ms} " <>
          "writer_peak_bytes=#{stats.peak_writer_process_bytes} reclaimed=#{stats.reclaimed_bytes}"
      )

      H.stop(root)

      {:ok, restarted} = H.restart(path, __MODULE__, workers: %{})
      assert Tay.status(name: __MODULE__).jobs == 10_000
      assert Tay.status(name: __MODULE__).blocked_jobs == 10_000
      H.stop(restarted)
    after
      File.rm_rf!(path)
    end
  end
end
