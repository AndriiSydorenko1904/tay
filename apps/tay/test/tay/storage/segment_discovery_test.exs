defmodule Tay.Storage.SegmentDiscoveryTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Reader, Segment}
  import Tay.Test.SegmentHelpers

  defp entry(name, fields \\ []),
    do: Enum.into(fields, %{name: name, type: :regular, links: 1, size: 44})

  defp name(id), do: elem(Segment.filename(id), 1)

  test "numeric discovery and harmless ordinary files" do
    assert {:ok, %{canonical: [{1, _}, {2, _}], unrelated: [_]}} =
             Reader.classify_entries(
               [entry(name(2)), entry("notes.txt"), entry(name(1))],
               :segments
             )

    assert {:error, %{reason: {:noncontiguous_ids, [1, 3]}}} =
             Reader.classify_entries([entry(name(1)), entry(name(3))], :segments)
  end

  test "malformed names, aliases, links, zero files and unexpected directories fail" do
    for e <- [
          entry("1.tay"),
          entry("1-copy.tay"),
          entry(name(1) <> ".bak"),
          entry(String.upcase(name(1))),
          entry(name(1), links: 2),
          entry(name(1), type: :symlink),
          entry(name(1), type: :directory),
          entry(name(1), size: 0),
          entry("dir", type: :directory)
        ] do
      assert {:error, %{kind: :discovery_error}} = Reader.classify_entries([e], :segments)
    end

    assert {:error, %{reason: {:duplicate_name, _}}} =
             Reader.classify_entries([entry(name(1)), entry(name(1))], :segments)
  end

  test "staging is constrained to exact names, types and header size" do
    stage = ".tay-new-00000000000000000002-" <> String.duplicate("a", 32) <> ".tmp"
    assert {:ok, %{staging: [_]}} = Reader.classify_entries([entry(stage)], :segments)

    for e <- [
          entry(stage, size: 45),
          entry(stage, type: :symlink),
          entry(stage <> "x"),
          entry(stage, links: 2)
        ] do
      assert {:error, _} = Reader.classify_entries([e], :segments)
    end
  end

  test "fixed S13 fails continuity, corrected S13 and S15 pass" do
    {:ok, one} = Segment.parse(fixture("s04.tay"))
    {:ok, three} = Segment.parse(fixture("s05.tay"))
    {:ok, next4} = Segment.parse(fixture("s13_next.tay"))
    {:ok, next2} = Segment.parse(fixture("s13_correct_next.tay"))

    assert {:error, %{reason: {:first_sequence, 2, 2, 4}}} =
             Reader.validate_topology([one, next4])

    assert {:ok, %{next_sequence: 2}} = Reader.validate_topology([one, next2])
    assert {:ok, %{next_sequence: 4}} = Reader.validate_topology([three, next4])
    assert {:ok, _} = Reader.validate_topology([one])
    assert {:error, _} = Reader.validate_topology([])
    assert {:error, _} = Reader.validate_topology([next4])
    assert {:error, _} = Reader.validate_topology([%{one | state: :active}, next2])
    assert {:error, _} = Reader.validate_topology([one, %{next2 | store_id: <<1::128>>}])
  end
end
