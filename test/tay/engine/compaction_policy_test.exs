defmodule Tay.Engine.CompactionPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Engine.{CompactionConfig, CompactionEstimate, CompactionPolicy, CompactionEvents}
  alias Tay.Storage.V2.{Authority, Codec, Reducer, Retention, Snapshot}
  alias Tay.Event.V1

  defp job(id, at, terminal) do
    definition = %{
      "args" => %{"bytes" => :binary.copy("x", rem(id, 4096))},
      "definition_version" => 1,
      "max_attempts" => 3,
      "queue_key" => "default",
      "retry_policy" => V1.policy(),
      "scheduled_at" => nil,
      "timeout_ms" => 1000,
      "worker_key" => "worker"
    }

    id = <<id::128>>

    {:ok, candidate} =
      Reducer.apply(Reducer.candidate(), %{
        job_id: id,
        kind: :inserted,
        expected_revision: 0,
        new_revision: 1,
        at: at,
        body: %{
          "definition" => definition,
          "eligible_at" => at,
          "availability_order" => 1
        }
      })

    if terminal do
      {:ok, candidate} =
        Reducer.apply(candidate, %{
          job_id: id,
          kind: :cancelled,
          expected_revision: 1,
          new_revision: 2,
          at: at,
          body: %{"execution_token" => nil}
        })

      candidate.jobs[id]
    else
      Map.put(candidate.jobs[id], :availability_order, :binary.decode_unsigned(id))
    end
  end

  test "strict finite config, shared duration bound, disabled opt-out" do
    assert {:ok, defaults} = CompactionConfig.new([])
    assert defaults.enabled
    assert {:ok, %{enabled: false}} = CompactionConfig.new(false)
    assert {:ok, _} = CompactionConfig.new(terminal_retention: {:hours, Retention.max_hours()})

    for options <- [
          nil,
          true,
          %{},
          [enabled: true, enabled: true],
          [unknown: 1],
          [enabled: nil],
          [terminal_retention: :infinity],
          [terminal_retention: {:hours, 0}],
          [terminal_retention: {:hours, Retention.max_hours() + 1}],
          [check_interval: :infinity],
          [check_interval: 0],
          [check_interval: 4_294_967_296],
          [min_interval: -1],
          [min_interval: 1.0],
          [min_sealed_segments: 0],
          [min_reclaimable_bytes: V1.max_time() + 1],
          [min_reclaimable_bytes: 0],
          [dead_ratio_threshold: 0],
          [dead_ratio_threshold: 1.01],
          [dead_ratio_threshold: :nan]
        ] do
      assert {:error, :compaction_configuration} = CompactionConfig.new(options)
    end
  end

  test "all gates conjunctive, cooldown equality and minimal generations do not churn" do
    c = CompactionConfig.defaults()

    s = %{
      last_compaction_at: nil,
      sealed_segments: c.min_sealed_segments,
      reclaimable_bytes: c.min_reclaimable_bytes,
      ratio: c.dead_ratio_threshold
    }

    assert :ok = CompactionPolicy.eligible(s, c, 10_000_000)

    assert {:error, :too_few_segments} =
             CompactionPolicy.eligible(%{s | sealed_segments: 0}, c, 10_000_000)

    assert {:error, :not_enough_reclaimable_bytes} =
             CompactionPolicy.eligible(
               %{s | reclaimable_bytes: c.min_reclaimable_bytes - 1},
               c,
               10_000_000
             )

    assert {:error, :ratio_below_threshold} =
             CompactionPolicy.eligible(
               %{s | ratio: c.dead_ratio_threshold - 0.001},
               c,
               10_000_000
             )

    s = %{s | last_compaction_at: 10_000_000}
    assert {:error, :cooldown} = CompactionPolicy.eligible(s, c, 9_999_999)
    assert {:error, :cooldown} = CompactionPolicy.eligible(s, c, 10_000_000 + c.min_interval - 1)
    assert :ok = CompactionPolicy.eligible(s, c, 10_000_000 + c.min_interval)

    {:ok, estimate} =
      CompactionEstimate.summarize(CompactionEstimate.new(), 44, 0, {:hours, 24}, 100_000_000)

    for _ <- 1..1000,
        do:
          assert(
            {:error, _} =
              CompactionPolicy.eligible(
                Map.put(estimate, :last_compaction_at, nil),
                c,
                100_000_000
              )
          )
  end

  property "candidate upper bound dominates worst one-segment-per-snapshot bytes and full authority metadata" do
    check all(
            count <- integer(0..40),
            hour <- integer(0..300),
            age <- integer(1..48),
            source_segments <- integer(0..150),
            max_runs: 100
          ) do
      jobs =
        Map.new(
          for id <- 1..count//1, do: {<<id::128>>, job(id, hour * 3_600_000, rem(id, 2) == 0)}
        )

      estimate =
        Enum.reduce(jobs, CompactionEstimate.new(), fn {_, j}, e ->
          CompactionEstimate.replace(e, nil, j)
        end)

      now = (hour + age) * 3_600_000
      {:ok, retained, _, stats} = Snapshot.prepare(jobs, {:hours, 24}, now)

      {:ok, summary} =
        CompactionEstimate.summarize(estimate, 100_000_000, source_segments, {:hours, 24}, now)

      base =
        Enum.with_index(retained, 1)
        |> Enum.map(fn {{_, j}, index} ->
          {:ok, bytes} = Codec.encode_snapshot(j)
          assert byte_size(bytes) + 28 + 108 <= CompactionEstimate.job_bound(j)

          %{
            id: index,
            first_sequence: index,
            last_sequence: index,
            bytes: byte_size(bytes) + 28 + 108,
            digest: <<0::256>>
          }
        end)

      manifest = %{
        store_id: <<1::128>>,
        epoch_id: <<2::128>>,
        source_epoch_id: nil,
        source_frontier: source_segments,
        captured_at: now,
        terminal_retention: {:hours, 24},
        source_segments: for(i <- 1..source_segments//1, do: %{id: i, digest: <<0::256>>}),
        base_segments: base,
        tail_segment_id: length(base) + 1,
        tail_first_sequence: length(base) + 1
      }

      {:ok, bytes} = Authority.encode_manifest(manifest)
      actual_upper = Enum.sum(Enum.map(base, & &1.bytes)) + 44 + byte_size(bytes) + 108 + 56
      assert summary.candidate_upper_bytes >= actual_upper
      assert summary.expired_terminals <= stats.expired_jobs
      assert summary.reclaimable_bytes <= max(0, 100_000_000 - actual_upper)
    end
  end

  test "summary memory capped; missing timestamps defer; retry subtracts expiry conservatively" do
    estimate =
      Enum.reduce(1..500, CompactionEstimate.new(), fn id, e ->
        CompactionEstimate.replace(e, nil, job(id, id * 3_600_000, true))
      end)

    assert map_size(estimate.buckets) == 128
    assert :erts_debug.flat_size(estimate) < 5000
    started = System.monotonic_time(:microsecond)

    for _ <- 1..10_000 do
      assert {:ok, _} =
               CompactionEstimate.summarize(
                 estimate,
                 100_000_000,
                 10,
                 {:hours, 24},
                 2_000_000_000
               )
    end

    IO.puts(
      "PHASE_C_ESTIMATOR 10000_evaluations_us=#{System.monotonic_time(:microsecond) - started} capped_summary_words=#{:erts_debug.flat_size(estimate)}"
    )

    old = job(1, 0, true)
    retried = %{old | state: :available, terminal_at: nil}

    e =
      CompactionEstimate.new()
      |> CompactionEstimate.replace(nil, old)
      |> CompactionEstimate.replace(old, retried)

    assert e.buckets == %{}

    assert {:ok, %{expired_terminals: 0}} =
             CompactionEstimate.summarize(e, 1_000_000, 1, {:hours, 1}, 10_000_000)

    e = CompactionEstimate.replace(e, nil, Map.delete(old, :terminal_at))

    assert {:error, :estimate_unavailable} =
             CompactionEstimate.summarize(e, 1_000_000, 1, {:hours, 1}, 10_000_000)
  end

  test "independent candidates bound terminal-only, active-only and policy replacement without replay" do
    for distribution <- [[], [false], [true], [true, true], [false, true, false]] do
      jobs =
        Map.new(Enum.with_index(distribution, 1), fn {terminal, id} ->
          {<<id::128>>, job(id, 3_600_000, terminal)}
        end)

      estimate =
        Enum.reduce(jobs, CompactionEstimate.new(), fn {_, j}, e ->
          CompactionEstimate.replace(e, nil, j)
        end)

      for hours <- [1, 24, 48] do
        {:ok, kept, _, _} = Snapshot.prepare(jobs, {:hours, hours}, 25 * 3_600_000)
        {:ok, independent} = Tay.Storage.V2.Epoch.build(kept, <<9::128>>)

        actual_segments =
          Enum.sum(Enum.map(independent.base, &byte_size(&1.bytes))) + byte_size(independent.tail)

        {:ok, summary} =
          CompactionEstimate.summarize(estimate, 100_000_000, 2, {:hours, hours}, 25 * 3_600_000)

        assert summary.candidate_upper_bytes >= actual_segments + 1_048_576
        assert summary.reclaimable_bytes <= 100_000_000 - actual_segments
        # Reusing the bounded acknowledged summary under a new policy needs no
        # replay. The 48-hour case is structural benefit with zero expiry.
        if hours == 48, do: assert(summary.expired_terminals == 0)
      end
    end
  end

  test "all terminal cutoff boundaries and extreme scalar profiles; nonterminals are protected" do
    template = job(1, 0, false)

    for state <- [
          :scheduled,
          :available,
          :executing,
          :retryable,
          :completed,
          :cancelled,
          :discarded
        ] do
      for at <- [99, 100, 101, V1.max_time()] do
        terminal = state in [:completed, :cancelled, :discarded]

        profile = %{
          template
          | state: state,
            revision: 18_446_744_073_709_551_615,
            cycle: 18_446_744_073_709_551_615,
            attempt: 3,
            next_attempt: if(terminal, do: nil, else: 3),
            eligible_at:
              if(state in [:available, :retryable, :scheduled], do: V1.max_time(), else: nil),
            availability_order:
              if(state == :available, do: 18_446_744_073_709_551_615, else: nil),
            attempted_at: V1.max_time(),
            inserted_at: V1.max_time(),
            completed_at: if(state == :completed, do: at, else: nil),
            terminal_at: if(terminal, do: at, else: nil),
            execution: if(state == :executing, do: 18_446_744_073_709_551_615, else: nil),
            diagnostic: %{"version" => 1, "code" => 7}
        }

        profile =
          if state == :scheduled,
            do: %{
              profile
              | revision: 1,
                cycle: 1,
                attempt: 0,
                next_attempt: 1,
                attempted_at: nil,
                diagnostic: nil
            },
            else: profile

        assert :ok = Codec.snapshot?(profile)
        {:ok, payload} = Codec.encode_snapshot(profile)
        assert byte_size(payload) + 28 + 108 <= CompactionEstimate.job_bound(profile)
        assert {:ok, expected} = Snapshot.classify(profile, {:hours, 1}, 3_600_100)
        assert expected == if(terminal and at <= 100, do: :expire, else: :retain)
      end
    end
  end

  test "telemetry strips all payloads, identifiers, unbounded labels and non-numeric measurements" do
    for event <- [
          :evaluation_performed,
          :evaluation_skipped,
          :compaction_eligible,
          :compaction_deferred,
          :automatic_compaction_started,
          :automatic_compaction_completed,
          :automatic_compaction_failed
        ] do
      assert %{event: ^event, reason: :publication_failed, source_bytes: 10} =
               CompactionEvents.normalize(event, {:raw, "secret"}, %{
                 source_bytes: 10,
                 args: "secret",
                 job_id: <<1::128>>,
                 recovered: %{jobs: %{}},
                 pause_ms: "payload"
               })

      assert map_size(
               CompactionEvents.normalize(event, :busy, %{source_bytes: 10, args: "secret"})
             ) == 3
    end

    assert {:ok, %{source_bytes: 1}} =
             CompactionEvents.result(
               {:ok, %{source_bytes: 1, recovered: %{jobs: %{}}, epoch_id: <<1::128>>}}
             )

    assert {:deferred, :insufficient_headroom} =
             CompactionEvents.result(
               {:error,
                Tay.Error.new(
                  :unknown_outcome,
                  {:compaction_failed, {:uncertain, :insufficient_headroom}}
                )}
             )

    assert {:deferred, :unable_to_drain} =
             CompactionEvents.result({:error, Tay.Error.new(:timeout, :draining)})

    assert {:error, :publication_failed} =
             CompactionEvents.result({:deferred, {:payload, "secret"}})
  end
end
