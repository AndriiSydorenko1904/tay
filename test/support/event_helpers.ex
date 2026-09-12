defmodule Tay.Test.EventHelpers do
  @moduledoc false
  alias Tay.Event
  @root Path.expand("../fixtures/events/v1", __DIR__)
  def fixture(id),
    do:
      File.read!(Path.join(@root, id <> ".hex"))
      |> String.replace(~r/\s/, "")
      |> Base.decode16!(case: :lower)

  def manifest do
    File.read!(Path.join(@root, "SHA256SUMS"))
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [hash, file] = String.split(line)
      {Path.rootname(file), hash}
    end)
  end

  def id(n \\ 1), do: <<n::128>>

  def definition(overrides \\ %{}) do
    Map.merge(
      %{
        "args" => %{},
        "definition_version" => 1,
        "max_attempts" => 2,
        "queue_key" => "q",
        "worker_key" => "w",
        "scheduled_at" => 10,
        "timeout_ms" => 30_000,
        "retry_policy" => %{
          "base_ms" => 1000,
          "cap_ms" => 60_000,
          "jitter_divisor" => 4,
          "version" => 1
        }
      },
      overrides
    )
  end

  def event(type, at, revision, fields \\ %{}, id \\ id()),
    do: %Event{
      record_type: type,
      data: Map.merge(%{"at" => at, "expected_revision" => revision, "job_id" => id}, fields)
    }

  def inserted(definition \\ definition(), at \\ 0, id \\ id()),
    do:
      event(
        1,
        at,
        0,
        %{"definition" => definition, "eligible_at" => definition["scheduled_at"] || at},
        id
      )

  def expected("E1"), do: inserted()
  def expected("E2"), do: event(2, 10, 1, %{"due_at" => 10})
  def expected("E3"), do: event(3, 10, 2, %{"attempt" => 1, "cycle_token" => 1})

  def expected("E4"),
    do:
      event(4, 11, 3, %{
        "diagnostic" => %{"code" => 1, "version" => 1},
        "disposition" => 1,
        "execution_token" => 3,
        "next_attempt" => 2,
        "next_due_at" => 1011,
        "outcome" => 1
      })

  def expected("E5"), do: event(5, 13, 5, %{"execution_token" => nil})
  def expected("E6"), do: event(6, 12, 4, %{"mode" => 0, "new_due_at" => 12})
end
