defmodule Tay.Storage.V2PhaseATest do
  use ExUnit.Case, async: true

  alias Tay.Storage.V2.{Codec, Reducer, Snapshot}
  alias Tay.Storage.Record
  alias Tay.Event.V1

  @id <<1::128>>
  @other <<2::128>>

  defp definition do
    %{
      "args" => %{"value" => 1},
      "definition_version" => 1,
      "max_attempts" => 3,
      "queue_key" => "default",
      "retry_policy" => V1.policy(),
      "scheduled_at" => nil,
      "timeout_ms" => 1_000,
      "worker_key" => "worker"
    }
  end

  defp insert(id, at \\ 100, order \\ 1) do
    %{
      job_id: id,
      kind: :inserted,
      expected_revision: 0,
      new_revision: 1,
      at: at,
      body: %{"definition" => definition(), "eligible_at" => at, "availability_order" => order}
    }
  end

  defp transition(id, kind, old, at, body) do
    %{job_id: id, kind: kind, expected_revision: old, new_revision: old + 1, at: at, body: body}
  end

  test "mutation and snapshot codecs round-trip a live job without physical positions" do
    inserted = insert(@id)
    assert {:ok, mutation_bytes} = Codec.encode_mutation(inserted)
    assert {:ok, ^inserted} = Codec.decode_mutation(mutation_bytes)
    assert {:ok, candidate} = Reducer.apply(Reducer.candidate(), inserted)
    job = candidate.jobs[@id]
    assert job.revision == 1
    assert job.cycle == 1
    assert job.availability_order == 1
    assert job.terminal_at == nil

    assert {:ok, snapshot_bytes} = Codec.encode_snapshot(job)
    assert {:ok, decoded} = Codec.decode_snapshot(snapshot_bytes)
    assert Map.drop(decoded, [:charge]) == Map.drop(job, [:charge])
    assert {:ok, restored} = Reducer.insert_snapshot(Reducer.candidate(), decoded)
    assert Reducer.durable_jobs(restored) == Reducer.durable_jobs(candidate)
  end

  test "logical revisions and execution tokens survive compaction" do
    {:ok, c1} = Reducer.apply(Reducer.candidate(), insert(@id))
    start = transition(@id, :started, 1, 100, %{"attempt" => 1, "cycle_token" => 1})
    {:ok, c2} = Reducer.apply(c1, start)
    assert c2.jobs[@id].execution == 2
    {:ok, bytes} = Codec.encode_snapshot(c2.jobs[@id])
    {:ok, snap} = Codec.decode_snapshot(bytes)
    {:ok, c3} = Reducer.insert_snapshot(Reducer.candidate(), snap)
    assert c3.jobs[@id].revision == 2
    assert c3.jobs[@id].execution == 2

    finish =
      transition(@id, :finished, 2, 101, %{
        "outcome" => 1,
        "disposition" => 1,
        "execution_token" => 2,
        "next_attempt" => 2,
        "next_due_at" => 1_101,
        "diagnostic" => %{"version" => 1, "code" => 1}
      })

    assert {:ok, c4} = Reducer.apply(c3, finish)
    assert c4.jobs[@id].revision == 3
    assert c4.jobs[@id].state == :retryable
    refute match?({:ok, _}, Reducer.apply(c4, finish))

    assert {:ok, c5} =
             Reducer.apply(
               c4,
               transition(@id, :available, 3, 1_101, %{
                 "due_at" => 1_101,
                 "availability_order" => 1
               })
             )

    assert c5.jobs[@id].availability_order == 1

    refute match?(
             {:ok, _},
             Reducer.apply(
               c5,
               transition(@id, :started, 4, 1_101, %{"attempt" => 2, "cycle_token" => 2})
             )
           )

    assert {:ok, c6} =
             Reducer.apply(
               c5,
               transition(@id, :started, 4, 1_101, %{"attempt" => 2, "cycle_token" => 1})
             )

    assert c6.jobs[@id].execution == 5
  end

  test "deterministic snapshots are sorted by job ID and retain terminals with infinity" do
    {:ok, a} = Reducer.apply(Reducer.candidate(), insert(@other))
    {:ok, b} = Reducer.apply(a, insert(@id, 100, 2))
    assert {:ok, first, %{expired_jobs: 0}} = Snapshot.plan(b.jobs)
    assert {:ok, ^first, _} = Snapshot.plan(b.jobs)

    assert Enum.map(first, fn bytes ->
             {:ok, job} = Codec.decode_snapshot(bytes)
             job.id
           end) == [@id, @other]
  end

  test "decoder rejects trailing bytes, unknown kinds, and unknown body keys" do
    assert {:ok, bytes} = Codec.encode_mutation(insert(@id))
    assert {:error, _} = Codec.decode_mutation(bytes <> <<0>>)
    <<prefix::binary-size(16), _kind, rest::binary>> = bytes
    assert {:error, :mutation_kind} = Codec.decode_mutation(prefix <> <<99>> <> rest)

    assert {:error, :mutation_keys} =
             Codec.decode_mutation(
               binary_part(bytes, 0, 41) <> elem(Tay.Event.Value.encode(%{"bogus" => 1}), 1)
             )

    duplicate_key_body =
      <<9, 2::32, 6, 1::32, "x", 0, 6, 1::32, "x", 0>>

    assert {:error, :map_order} =
             Codec.decode_mutation(binary_part(bytes, 0, 41) <> duplicate_key_body)

    oversized = :binary.copy(<<0>>, 16_777_217)
    assert {:error, :payload_too_large} = Codec.decode_mutation(oversized)
    assert {:error, :payload_too_large} = Codec.decode_snapshot(oversized)
  end

  test "snapshot decoder rejects inconsistent terminal timestamps" do
    {:ok, candidate} = Reducer.apply(Reducer.candidate(), insert(@id))
    {:ok, payload} = Codec.encode_snapshot(candidate.jobs[@id])
    <<prefix::binary-size(33), body_bytes::binary>> = payload
    {:ok, body} = Tay.Event.Value.decode(body_bytes)

    {:ok, invalid_body} = Tay.Event.Value.encode(Map.put(body, "terminal_at", 101))
    assert {:error, :terminal_at} = Codec.decode_snapshot(prefix <> invalid_body)

    {:ok, cancelled} =
      Reducer.apply(
        candidate,
        transition(@id, :cancelled, 1, 101, %{"execution_token" => nil})
      )

    {:ok, cancelled_payload} = Codec.encode_snapshot(cancelled.jobs[@id])
    <<cancelled_prefix::binary-size(33), cancelled_body_bytes::binary>> = cancelled_payload
    {:ok, cancelled_body} = Tay.Event.Value.decode(cancelled_body_bytes)
    {:ok, invalid_body} = Tay.Event.Value.encode(Map.put(cancelled_body, "terminal_at", nil))
    assert {:error, :terminal_at} = Codec.decode_snapshot(cancelled_prefix <> invalid_body)

    {:ok, started} =
      Reducer.apply(
        candidate,
        transition(@id, :started, 1, 100, %{"attempt" => 1, "cycle_token" => 1})
      )

    {:ok, completed} =
      Reducer.apply(
        started,
        transition(@id, :finished, 2, 101, %{
          "outcome" => 0,
          "disposition" => 0,
          "execution_token" => 2,
          "next_attempt" => nil,
          "next_due_at" => nil,
          "diagnostic" => nil
        })
      )

    {:ok, completed_payload} = Codec.encode_snapshot(completed.jobs[@id])
    <<completed_prefix::binary-size(33), completed_body_bytes::binary>> = completed_payload
    {:ok, completed_body} = Tay.Event.Value.decode(completed_body_bytes)
    {:ok, invalid_body} = Tay.Event.Value.encode(Map.put(completed_body, "terminal_at", 102))
    assert {:error, :terminal_at} = Codec.decode_snapshot(completed_prefix <> invalid_body)
  end

  test "global availability order preserves equal-due FIFO when job IDs sort differently" do
    {:ok, a} = Reducer.apply(Reducer.candidate(), insert(@other))
    {:ok, b} = Reducer.apply(a, insert(@id, 100, 2))
    assert b.jobs[@other].revision == b.jobs[@id].revision
    assert b.jobs[@other].eligible_at == b.jobs[@id].eligible_at
    assert queue_ids(b.jobs) == [@other, @id]
    assert {:ok, payloads, %{next_availability_order: 3}} = Snapshot.plan(b.jobs)
    {:ok, restored} = restore(payloads)
    assert queue_ids(restored.jobs) == [@other, @id]
    assert {:ok, twice, _} = Snapshot.plan(restored.jobs)
    {:ok, restored_twice} = restore(twice)
    assert queue_ids(restored_twice.jobs) == [@other, @id]
  end

  test "one thousand equal-due jobs retain FIFO through recovery and two compactions" do
    total = 1_000
    due = 100

    {:ok, inserted} =
      Enum.reduce(1..total, {:ok, Reducer.candidate()}, fn index, {:ok, candidate} ->
        id = <<total + 1 - index::128>>

        mutation =
          if index <= div(total, 2) do
            insert(id, due, index)
          else
            insert(id, 10, nil)
            |> put_in([:body, "eligible_at"], due)
            |> put_in([:body, "definition", "scheduled_at"], due)
          end

        Reducer.apply(candidate, mutation)
      end)

    {:ok, source} =
      Enum.reduce((div(total, 2) + 1)..total, {:ok, inserted}, fn index, {:ok, candidate} ->
        id = <<total + 1 - index::128>>

        Reducer.apply(
          candidate,
          transition(id, :available, 1, due, %{
            "due_at" => due,
            "availability_order" => index
          })
        )
      end)

    expected = Enum.map(1..total, fn index -> <<total + 1 - index::128>> end)
    assert queue_ids(source.jobs) == expected
    assert source.jobs[hd(expected)].revision == 1
    assert source.jobs[List.last(expected)].revision == 2

    assert {:ok, first, %{next_availability_order: 1_001}} = Snapshot.plan(source.jobs)
    assert {:ok, recovered} = restore(first)
    assert queue_ids(recovered.jobs) == expected

    assert {:ok, second, _} = Snapshot.plan(recovered.jobs)
    assert first == second
    assert {:ok, recovered_twice} = restore(second)
    assert queue_ids(recovered_twice.jobs) == expected

    later_id = <<total + 1::128>>
    assert {:ok, later} = Reducer.apply(recovered_twice, insert(later_id, due, 1_001))
    assert queue_ids(later.jobs) == expected ++ [later_id]
  end

  test "duplicate snapshot orders and exhausted global allocator fail closed" do
    {:ok, first} = Reducer.apply(Reducer.candidate(), insert(@id))
    {:ok, second} = Reducer.apply(first, insert(@other, 100, 2))
    duplicate = %{second.jobs[@other] | availability_order: 1}

    assert {:error, :duplicate_availability_order} = Reducer.insert_snapshot(first, duplicate)
    invalid_source = Map.put(second.jobs, @other, duplicate)
    assert {:error, :duplicate_availability_order} = Snapshot.plan(invalid_source)
    refute Snapshot.equivalent?(invalid_source, second.jobs)

    max = 18_446_744_073_709_551_615
    max_order = %{first.jobs[@id] | availability_order: max}
    assert {:ok, exhausted} = Reducer.insert_snapshot(Reducer.candidate(), max_order)
    assert exhausted.next_availability_order == max + 1
    assert {:error, :availability_order} = Reducer.apply(exhausted, insert(@other, 100, max + 1))
  end

  test "literal Record-v1 frames anchor every Store-v2 payload family" do
    fixture = Path.expand("../../fixtures/storage/v2/records.hex", __DIR__)

    for line <- fixture |> File.read!() |> String.split("\n", trim: true) do
      [label, hex] = String.split(line, ":", parts: 2)
      {:ok, bytes} = Base.decode16(hex, case: :lower)
      assert {:ok, record, <<>>} = Record.decode(bytes)
      assert record.payload_schema_version == 1

      encoded =
        if label == "snapshot" do
          assert record.record_type == Codec.snapshot_type()
          {:ok, job} = Codec.decode_snapshot(record.payload)
          Codec.encode_snapshot(job)
        else
          assert record.record_type == Codec.mutation_type()
          {:ok, mutation} = Codec.decode_mutation(record.payload)
          assert Atom.to_string(mutation.kind) == label
          Codec.encode_mutation(mutation)
        end

      assert encoded == {:ok, record.payload}
      assert Record.encode(record) == {:ok, bytes}
    end
  end

  test "administrative retry resets cycle and interrupted execution keeps its attempt" do
    inserted = put_in(insert(@id).body["definition"]["max_attempts"], 1)
    {:ok, c1} = Reducer.apply(Reducer.candidate(), inserted)

    {:ok, c2} =
      Reducer.apply(c1, transition(@id, :started, 1, 100, %{"attempt" => 1, "cycle_token" => 1}))

    discard =
      transition(@id, :finished, 2, 101, %{
        "outcome" => 1,
        "disposition" => 2,
        "execution_token" => 2,
        "next_attempt" => nil,
        "next_due_at" => nil,
        "diagnostic" => %{"version" => 1, "code" => 1}
      })

    {:ok, c3} = Reducer.apply(c2, discard)
    assert c3.jobs[@id].state == :discarded

    assert c3.jobs[@id].terminal_at == 101
    assert {:ok, :expire} = Snapshot.classify(c3.jobs[@id], {:hours, 1}, 4_000_000)
    assert {:ok, :retain} = Snapshot.classify(c3.jobs[@id], {:hours, 1}, 101)

    {:ok, c4} =
      Reducer.apply(
        c3,
        transition(@id, :retried, 3, 102, %{
          "mode" => 1,
          "new_due_at" => 102,
          "availability_order" => 2
        })
      )

    assert c4.jobs[@id].cycle == 4
    assert c4.jobs[@id].attempt == 0
    assert c4.jobs[@id].terminal_at == nil

    assert {:ok, c5} =
             Reducer.apply(
               c4,
               transition(@id, :started, 4, 102, %{"attempt" => 1, "cycle_token" => 4})
             )

    interrupted =
      transition(@id, :finished, 5, 103, %{
        "outcome" => 3,
        "disposition" => 1,
        "execution_token" => 5,
        "next_attempt" => 1,
        "next_due_at" => 1_103,
        "diagnostic" => %{"version" => 1, "code" => 7}
      })

    {:ok, c6} = Reducer.apply(c5, interrupted)
    assert c6.jobs[@id].attempt == 1
    assert c6.jobs[@id].next_attempt == 1
    {:ok, bytes} = Codec.encode_snapshot(c6.jobs[@id])
    {:ok, snap} = Codec.decode_snapshot(bytes)
    {:ok, c7} = Reducer.insert_snapshot(Reducer.candidate(), snap)

    {:ok, c8} =
      Reducer.apply(
        c7,
        transition(@id, :available, 6, 1_103, %{
          "due_at" => 1_103,
          "availability_order" => 1
        })
      )

    refute match?(
             {:ok, _},
             Reducer.apply(
               c8,
               transition(@id, :started, 7, 1_103, %{"attempt" => 1, "cycle_token" => 1})
             )
           )

    assert {:ok, c9} =
             Reducer.apply(
               c8,
               transition(@id, :started, 7, 1_103, %{"attempt" => 1, "cycle_token" => 4})
             )

    assert c9.jobs[@id].execution == 8
  end

  test "executing cancellation fences its token and revision overflow fails before append" do
    {:ok, c1} = Reducer.apply(Reducer.candidate(), insert(@id))

    {:ok, c2} =
      Reducer.apply(c1, transition(@id, :started, 1, 100, %{"attempt" => 1, "cycle_token" => 1}))

    assert {:error, _} =
             Reducer.apply(c2, transition(@id, :cancelled, 2, 101, %{"execution_token" => 1}))

    {:ok, c3} = Reducer.apply(c2, transition(@id, :cancelled, 2, 101, %{"execution_token" => 2}))
    assert c3.jobs[@id].state == :cancelled
    assert c3.jobs[@id].execution == nil
    assert c3.jobs[@id].terminal_at == 101

    assert {:error, _} =
             Reducer.apply(c3, transition(@id, :cancelled, 3, 102, %{"execution_token" => 2}))

    max = 18_446_744_073_709_551_615
    overflow = transition(@id, :cancelled, max, 102, %{"execution_token" => nil})
    assert {:error, :revision} = Codec.encode_mutation(overflow)
  end

  defp restore(payloads) do
    Enum.reduce_while(payloads, {:ok, Reducer.candidate()}, fn payload, {:ok, candidate} ->
      with {:ok, job} <- Codec.decode_snapshot(payload),
           {:ok, next} <- Reducer.insert_snapshot(candidate, job) do
        {:cont, {:ok, next}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp queue_ids(jobs) do
    jobs
    |> Enum.filter(fn {_, job} -> job.state == :available end)
    |> Enum.sort_by(fn {id, job} ->
      {job.definition["queue_key"], job.eligible_at, job.availability_order, id}
    end)
    |> Enum.map(&elem(&1, 0))
  end
end
