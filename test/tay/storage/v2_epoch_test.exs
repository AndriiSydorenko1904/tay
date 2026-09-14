defmodule Tay.Storage.V2EpochTest do
  use ExUnit.Case, async: true

  alias Tay.Event.V1
  alias Tay.Storage.{Record, Segment}
  alias Tay.Storage.V2.{Codec, Epoch, Reducer, Snapshot}

  @store <<9::128>>
  @a <<2::128>>
  @b <<1::128>>

  defp definition do
    %{
      "args" => %{},
      "definition_version" => 1,
      "max_attempts" => 3,
      "queue_key" => "default",
      "retry_policy" => V1.policy(),
      "scheduled_at" => nil,
      "timeout_ms" => 1_000,
      "worker_key" => "worker"
    }
  end

  defp insert(id, order) do
    %{
      job_id: id,
      kind: :inserted,
      expected_revision: 0,
      new_revision: 1,
      at: 100,
      body: %{
        "definition" => definition(),
        "eligible_at" => 100,
        "availability_order" => order
      }
    }
  end

  test "candidate has sealed snapshot base, synced-shape empty tail and exact semantic replay" do
    {:ok, one} = Reducer.apply(Reducer.candidate(), insert(@a, 1))
    {:ok, source} = Reducer.apply(one, insert(@b, 2))
    assert {:ok, epoch} = Epoch.build(source.jobs, @store)
    assert length(epoch.base) == 1
    assert epoch.tail_segment_id == 2
    assert epoch.tail_first_sequence == 3
    assert epoch.next_availability_order == 3

    assert {:ok, %{state: :sealed, count: 2}} =
             Segment.parse(hd(epoch.base).bytes, id: 1, store_id: @store, highest: false)

    assert {:ok, %{state: :active, count: 0}} =
             Segment.parse(epoch.tail, id: 2, store_id: @store, highest: true)

    assert {:ok, restored} = Epoch.recover(Enum.map(epoch.base, & &1.bytes), [epoch.tail], @store)
    assert Snapshot.equivalent?(source.jobs, restored.jobs)
    assert restored.jobs[@a].availability_order == 1
    assert restored.jobs[@b].availability_order == 2
  end

  test "empty retained state has no base and tail starts at physical sequence one" do
    assert {:ok, %{base: [], tail_segment_id: 1, tail_first_sequence: 1} = epoch} =
             Epoch.build(%{}, @store)

    assert {:ok, restored} = Epoch.recover([], [epoch.tail], @store)
    assert restored.jobs == %{}
  end

  test "post-snapshot mutation uses logical revision despite physical sequence reset" do
    {:ok, first} = Reducer.apply(Reducer.candidate(), insert(@a, 1))
    {:ok, epoch} = Epoch.build(first.jobs, @store)

    started = %{
      job_id: @a,
      kind: :started,
      expected_revision: 1,
      new_revision: 2,
      at: 100,
      body: %{"attempt" => 1, "cycle_token" => 1}
    }

    {:ok, payload} = Codec.encode_mutation(started)

    {:ok, frame} =
      Record.encode(%Record{
        record_type: 8,
        payload_schema_version: 1,
        sequence: 2,
        payload: payload
      })

    assert {:ok, recovered} =
             Epoch.recover(Enum.map(epoch.base, & &1.bytes), [epoch.tail <> frame], @store)

    assert recovered.jobs[@a].revision == 2
    assert recovered.jobs[@a].execution == 2
    assert recovered.jobs[@a].availability_order == nil

    assert {:error, _} =
             Epoch.recover(
               Enum.map(epoch.base, & &1.bytes),
               [epoch.tail <> frame <> <<0>>],
               @store
             )
  end

  test "candidate mismatch and malformed physical topology fail closed" do
    {:ok, one} = Reducer.apply(Reducer.candidate(), insert(@a, 1))
    {:ok, epoch} = Epoch.build(one.jobs, @store)
    assert {:error, _} = Epoch.recover([epoch.tail], [epoch.tail], @store)
    assert {:error, _} = Epoch.recover(Enum.map(epoch.base, & &1.bytes), [], @store)

    <<head, rest::binary>> = hd(epoch.base).bytes

    assert {:error, _} =
             Epoch.recover([<<Bitwise.bxor(head, 1), rest::binary>>], [epoch.tail], @store)
  end
end
