defmodule Tay.Storage.SegmentParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Storage.Segment
  import Tay.Test.SegmentHelpers
  alias Tay.Test.RecordHelpers, as: R

  test "permanent active and sealed fixtures" do
    for {file, state, count} <- [
          {"s01.tay", :active, 0},
          {"s02.tay", :active, 1},
          {"s03.tay", :active, 3},
          {"s04.tay", :sealed, 1},
          {"s05.tay", :sealed, 3}
        ] do
      assert {:ok, segment} = Segment.parse(fixture(file), id: 1, store_id: store_id())
      assert segment.state == state
      assert segment.count == count
      assert segment.bytes == byte_size(fixture(file))
    end
  end

  test "permanent adversarial fixtures preserve classifications" do
    for {file, kind} <- [
          {"s06.tay", :corrupt_segment_header},
          {"s08.tay", :corrupt_footer},
          {"s09.tay", :segment_crc},
          {"s11.tay", :record_or_sequence_error},
          {"s12_tail.tay", :corrupt_footer},
          {"s12_duplicate.tay", :corrupt_footer},
          {"s14.tay", :corrupt_segment_header}
        ] do
      assert {:error, %{kind: ^kind}} = Segment.parse(fixture(file))
    end

    assert {:error, %{kind: :id_or_store_mismatch}} = Segment.parse(fixture("s07.tay"), id: 2)

    for n <- [1, 3, 4, 36, 63] do
      kind = if n < 4, do: :ambiguous_short_tail, else: :incomplete_footer
      assert {:error, %{kind: ^kind, offset: 72}} = Segment.parse(fixture("s10_#{n}.tay"))

      assert {:error, %{kind: :sealed_history_error}} =
               Segment.parse(fixture("s10_#{n}.tay"), highest: false)
    end
  end

  test "every partial footer is classified, never ignored" do
    bytes = fixture("s04.tay")

    for n <- 1..63 do
      assert {:error, %{offset: 72}} = Segment.parse(binary_part(bytes, 0, 72 + n))
    end

    assert {:error, %{kind: :sealed_history_error}} =
             Segment.parse(fixture("s01.tay"), highest: false)
  end

  test "unknown semantics remain physical records; payload magic is opaque" do
    r = R.frame(record_type: 47, payload_schema_version: 3, payload: "TAYF" <> <<0::512>>)
    assert {:ok, %{count: 1}} = Segment.parse(header() <> r)
  end

  test "length CRC corruption never conceals a following good record" do
    bad = R.flip(R.frame(payload: "abc"), 16, 0)
    bytes = header() <> bad <> R.frame(sequence: 2)

    assert {:error, %{offset: 44, reason: {:error, {:corrupt, :header_checksum}}}} =
             Segment.parse(bytes)
  end

  test "size and decoder budgets are distinct and bounded before allocation" do
    bytes = header() <> R.frame(payload: "abc")

    assert {:error, %{kind: :io_or_resource_error, reason: {:error, {:resource_limit, 3, 2}}}} =
             Segment.parse(bytes, max_decode_payload_bytes: 2)

    read = fn offset, length ->
      assert {offset, length} == {0, 44}
      {:ok, header()}
    end

    assert {:error, %{reason: :segment_size_exceeds_format}} =
             Segment.scan(read, Segment.max_bytes() + 1)

    assert {:error, %{kind: :io_or_resource_error}} = Segment.scan(fn _, _ -> {:ok, <<>>} end, 44)
  end

  test "every single-bit mutation of a fixed sealed segment fails physical validation" do
    bytes = fixture("s05.tay")

    for offset <- 0..(byte_size(bytes) - 1), bit <- 0..7 do
      assert {:error, _} = Segment.parse(R.flip(bytes, offset, bit))
    end
  end

  test "unsupported segment flags remain an unsupported physical feature" do
    assert {:error, %{kind: :unsupported_segment_flags}} = Segment.parse(header(flags: 1))
    h = header()
    r = R.frame()

    assert {:error, %{kind: :unsupported_segment_flags}} =
             Segment.parse(h <> r <> footer(h, [r], flags: 1))
  end

  property "arbitrary records parse with bounded reads, ordering and opaque payloads" do
    check all(
            payloads <- list_of(binary(max_length: 150), min_length: 1, max_length: 12),
            sealed <- boolean()
          ) do
      records =
        Enum.with_index(payloads, 1)
        |> Enum.map(fn {p, i} -> R.frame(sequence: i, payload: p) end)

      h = header()
      bytes = IO.iodata_to_binary([h, records, if(sealed, do: footer(h, records), else: <<>>)])

      read = fn offset, length ->
        assert length <= 178
        {:ok, binary_part(bytes, offset, length)}
      end

      assert {:ok, summary, seen} =
               Segment.reduce(read, byte_size(bytes), [], fn r, _, acc -> [r.payload | acc] end)

      assert Enum.reverse(seen) == payloads
      assert summary.count == length(payloads)
      assert summary.state == if(sealed, do: :sealed, else: :active)
    end
  end
end
