Code.require_file("../../../bench/harness.exs", __DIR__)

defmodule Tay.Qualification.BenchmarkTest do
  use ExUnit.Case, async: false
  alias Tay.Bench.{Harness, Stats}
  alias Tay.Test.NativeHelpers
  @moduletag capture_log: true

  setup do
    Process.flag(:trap_exit, true)
    path = NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "nearest-rank distributions and absent measurements serialize honestly" do
    assert %{count: 0, p95: nil, p99: nil} = Stats.distribution([])
    assert %{count: 100, p50: 50, p95: 95, p99: 99} = Stats.distribution(Enum.to_list(1..100))
    assert %{count: 1, p95: 7, p99: 7} = Stats.distribution([7])

    assert :json.decode(Stats.json(%{unmeasured: nil, passed: true, retention: {:hours, 24}})) ==
             %{"unmeasured" => :null, "passed" => true, "retention" => ["hours", 24]}
  end

  test "literal Event domains prove conservative maximum active-outcome frame sizes" do
    common = %{
      "at" => 9_223_372_036_854_775_807,
      "expected_revision" => 18_446_744_073_709_551_615,
      "job_id" => <<1::128>>,
      "execution_token" => 18_446_744_073_709_551_615
    }

    finish = %Tay.Event{
      record_type: 4,
      data:
        Map.merge(common, %{
          "diagnostic" => %{"code" => 1, "version" => 1},
          "disposition" => 1,
          "next_attempt" => 65_535,
          "next_due_at" => 9_223_372_036_854_775_807,
          "outcome" => 1
        })
    }

    assert {:ok, {4, 1, payload}} = Tay.Event.encode(finish)
    assert byte_size(payload) == 269
    assert byte_size(payload) + 28 == 297

    assert {:ok, {5, 1, payload}} =
             Tay.Event.encode(%Tay.Event{record_type: 5, data: common})

    assert byte_size(payload) == 113
    assert byte_size(payload) + 28 == 141
    assert 297 + 64 + 44 < 1_132
  end

  test "options reject unsafe paths, silent options and false qualification labels", %{path: path} do
    assert {:ok, _} = Harness.options(%{path: path, mode: :write})

    for change <- [
          %{path: "relative"},
          %{jobs: 0},
          %{clients: 65},
          %{args_bytes: 262_001},
          %{unknown: true},
          %{replay_segments: [1, 1]},
          %{mode: :sync}
        ] do
      assert {:error, :invalid_benchmark_options} =
               Harness.options(Map.merge(%{path: path, mode: :write}, change))
    end
  end

  test "small lifecycle observes real ACK, callback and three durable event receipts", %{
    path: path
  } do
    result =
      Harness.run(:lifecycle, %{path: path, mode: :write, jobs: 4, args_bytes: 32, clients: 2})

    m = result.measurements
    assert m.jobs == 4
    assert m.status.jobs == 4
    assert m.insert_roundtrip_us.count == 4
    assert m.start_receipt_to_callback_us.count == 4
    assert m.worker_return_to_finish_receipt_us.count == 4
    assert m.physical_append_receipt_us["1"].count == 4
    assert m.physical_append_receipt_us["3"].count == 4
    assert m.physical_append_receipt_us["4"].count == 4
    assert m.canonical_bytes == m.status.canonical_history_bytes
    assert m.ready_private_ets_bytes > 0
    assert m.restart.within_configured_deadline
    assert m.restart.sampled_peak.samples > 0
    assert m.indexed_call_counts["Tay.State.JobIndex.get/2"] > 0
    assert m.indexed_call_counts["Tay.State.QueueIndex.take/6"] > 0
    assert m.callback_counts_by_queue == %{alpha: 2, beta: 2}

    assert_raise RuntimeError, ~r/new path/, fn ->
      Harness.run(:lifecycle, %{path: path, mode: :write})
    end
  end

  test "compact topology uses real legal rotations and production semantic recovery", %{
    path: path
  } do
    result =
      Harness.run(:replay, %{path: path, mode: :write, args_bytes: 32, replay_segments: [1, 2]})

    assert Enum.map(result.measurements, & &1.segments) == [1, 2]

    for m <- result.measurements do
      assert m.kind == :compact_manually_rotated_history
      assert m.jobs == m.status.jobs
      assert m.status.segment_count == m.segments
      assert m.canonical_bytes == m.status.canonical_history_bytes
      assert m.within_configured_deadline
      assert m.status.blocked_jobs == 0
    end
  end

  test "real history-budget refusal preserves an active finish reservation", %{path: path} do
    result = Harness.run(:reserve, %{path: path, mode: :write})
    m = result.measurements
    assert m.refusal == %{kind: :capacity, reason: :max_history_bytes}
    assert m.active_status.reserved_outcome_bytes > 0
    assert m.settled_status.reserved_outcome_bytes == 0
    assert m.settled_status.canonical_history_bytes <= m.max_history_bytes
    assert m.worker_return_to_finish_receipt_us.count == 1
  end

  test "idle and insertion-load probes report each queue without assuming saturation", %{
    path: path
  } do
    result =
      Harness.run(:schedule, %{path: path, mode: :write, jobs: 4, args_bytes: 32, clients: 2})

    m = result.measurements
    assert m.idle_schedule_lag_ms.count == 4
    assert m.insertion_load_schedule_lag_ms.count == 4
    assert m.load_insertions > 0

    for queue <- [:alpha, :beta] do
      assert m.idle_queue_lag_ms[queue].count == 2
      assert m.insertion_load_queue_lag_ms[queue].count == 2
    end

    assert m.saturated_label_proven == m.insert_calls_overlapping_probe_due >= 2
  end
end
