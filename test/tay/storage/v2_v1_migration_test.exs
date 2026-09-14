defmodule Tay.Storage.V2V1MigrationTest do
  use ExUnit.Case, async: true

  alias Tay.Event
  alias Tay.Event.V1
  alias Tay.Storage.V2.{Snapshot, V1Migration}

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

  defp event(type, id, expected, at, body) do
    %Event{
      record_type: type,
      data: Map.merge(body, %{"job_id" => id, "expected_revision" => expected, "at" => at})
    }
  end

  test "V1 replay projects logical revisions, equal-due order and terminal timestamps" do
    inserted = %{"definition" => definition(), "eligible_at" => 100}

    {:ok, first} =
      V1Migration.reduce(V1Migration.candidate(), event(1, @a, 0, 100, inserted), %{sequence: 1})

    {:ok, second} = V1Migration.reduce(first, event(1, @b, 0, 100, inserted), %{sequence: 2})

    assert second.v2.jobs[@a].revision == 1
    assert second.v2.jobs[@b].revision == 1
    assert second.v2.jobs[@a].availability_order == 1
    assert second.v2.jobs[@b].availability_order == 2
    assert {:ok, _, %{next_availability_order: 3}} = Snapshot.plan(second.v2.jobs)

    {:ok, third} =
      V1Migration.reduce(
        second,
        event(3, @a, 1, 100, %{"attempt" => 1, "cycle_token" => 1}),
        %{sequence: 3}
      )

    assert third.v2.jobs[@a].execution == 2
    assert third.v1.jobs[@a].execution == 3

    {:ok, fourth} =
      V1Migration.reduce(
        third,
        event(4, @a, 3, 101, %{
          "outcome" => 1,
          "disposition" => 1,
          "execution_token" => 3,
          "next_attempt" => 2,
          "next_due_at" => 1_101,
          "diagnostic" => %{"version" => 1, "code" => 1}
        }),
        %{sequence: 4}
      )

    {:ok, fifth} =
      V1Migration.reduce(
        fourth,
        event(2, @a, 4, 1_101, %{"due_at" => 1_101}),
        %{sequence: 5}
      )

    assert fifth.v2.jobs[@a].revision == 4
    assert fifth.v2.jobs[@a].availability_order == 3
    assert fifth.v2.jobs[@a].cycle == 1

    {:ok, sixth} =
      V1Migration.reduce(
        fifth,
        event(5, @b, 2, 102, %{"execution_token" => nil}),
        %{sequence: 6}
      )

    assert sixth.v2.jobs[@b].revision == 2
    assert sixth.v2.jobs[@b].terminal_at == 102
    assert sixth.v2.jobs[@b].availability_order == nil
    assert {:ok, :expire} = Snapshot.classify(sixth.v2.jobs[@b], {:hours, 1}, 3_600_102)

    assert {:error, :v1_physical_sequence} =
             V1Migration.reduce(sixth, event(5, @b, 2, 103, %{"execution_token" => nil}), %{
               sequence: 8
             })
  end
end
