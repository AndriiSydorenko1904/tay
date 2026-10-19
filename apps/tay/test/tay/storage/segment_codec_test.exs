defmodule Tay.Storage.SegmentCodecTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Segment
  alias Tay.Test.{SegmentHelpers, ReferenceCRC32C}
  import SegmentHelpers

  test "STORE and header are independently fixed compatibility bytes" do
    assert {:ok, fixture("STORE")} == Segment.encode_store(store_id())
    assert {:ok, store_id()} == Segment.decode_store(fixture("STORE"))

    assert {:ok, fixture("s01.tay")} ==
             Segment.encode_header(%{
               id: 1,
               first_sequence: 1,
               store_id: store_id()
             })

    assert {:ok, %Segment{id: 1, first_sequence: 1}} = Segment.decode_header(fixture("s01.tay"))
    assert header() == fixture("s01.tay")
  end

  test "both whole-segment and footer CRCs agree with independent oracle" do
    for {file, count, last} <- [{"s04.tay", 1, 1}, {"s05.tay", 3, 3}] do
      bytes = fixture(file)
      size = byte_size(bytes) - 64
      <<prefix::binary-size(^size), body::binary-size(60), crc::32>> = bytes
      assert ReferenceCRC32C.checksum(body) == crc
      footer_bytes = binary_part(bytes, size, 64)

      expected = %{
        id: 1,
        first_sequence: 1,
        last_sequence: last,
        count: count,
        store_id: store_id(),
        segment_crc: ReferenceCRC32C.checksum(prefix)
      }

      assert {:ok, ^expected} = Segment.decode_footer(footer_bytes, expected)
      assert {:ok, ^footer_bytes} = Segment.encode_footer(expected)
    end
  end

  test "reserved fields are checked after their CRC; version precedes layout" do
    assert {:error, :reserved_bytes} = Segment.decode_header(header(reserved: 1))
    assert {:error, {:unsupported_flags, 1}} = Segment.decode_header(header(flags: 1))
    assert {:error, {:unsupported_version, 2}} = Segment.decode_header(<<"TAYS", 2>>)
    assert {:error, {:invalid_version, 0}} = Segment.decode_header(<<"TAYS", 0>>)
    assert {:error, :checksum} = Segment.decode_header(fixture("s06.tay"))
    assert {:error, :invalid_store_id} = Segment.decode_store(fixture("s14_STORE"))
    assert {:error, :invalid_store_id} = Segment.decode_header(fixture("s14.tay"))
    assert {:error, :trailing_store_bytes} = Segment.decode_store(fixture("STORE") <> <<0>>)
  end

  test "all header cuts are incomplete and never consume data" do
    for n <- 0..43 do
      assert {:incomplete, 44} = Segment.decode_header(binary_part(fixture("s01.tay"), 0, n))
    end

    assert {:error, :invalid_magic} = Segment.decode_header("X")
  end

  test "canonical 20-digit filename and integer boundaries" do
    for id <- [1, 42, Segment.max_id()] do
      assert {:ok, name} = Segment.filename(id)
      assert byte_size(name) == 24
      assert {:ok, ^id} = Segment.filename_id(name)
    end

    for bad <- [0, -1, Segment.max_id() + 1, 1.0, nil],
        do: assert({:error, _} = Segment.filename(bad))

    for bad <- [
          "0000000000000001.tay",
          "00000000000000000001.TAY",
          "18446744073709551616.tay",
          "00000000000000000000.tay",
          "1-copy.tay"
        ],
        do: assert({:error, _} = Segment.filename_id(bad))
  end

  test "footer checksum precedes metadata, which precedes cross-checks" do
    h = header()
    r = Tay.Test.RecordHelpers.frame()
    assert {:error, :invalid_record_count} = Segment.decode_footer(footer(h, [r], count: 0))

    assert {:error, {:mismatch, :id, 1, 2}} =
             Segment.decode_footer(footer(h, [r], id: 2, last_sequence: 8), %{id: 1})

    assert {:error, :count_sequence_relation} =
             Segment.decode_footer(footer(h, [r], last_sequence: 8))

    assert {:error, :invalid_record_count} =
             Segment.encode_footer(%{
               id: 1,
               first_sequence: 1,
               last_sequence: 1,
               count: 0,
               store_id: store_id(),
               segment_crc: 0
             })
  end

  test "literal manifest anchors every permanent fixture byte" do
    dir = Path.expand("../../fixtures/storage/segment/v1", __DIR__)
    {fixtures, _} = Code.eval_file(Path.join(dir, "manifest.exs"))

    for {name, hex} <- fixtures,
        do: assert(File.read!(Path.join(dir, name)) == Base.decode16!(hex, case: :lower))
  end

  test "footer ID comparison precedes identity and count relation" do
    h = header()
    r = Tay.Test.RecordHelpers.frame()
    bytes = footer(h, [r], id: 2, store_id: <<0::128>>, last_sequence: 8)
    assert {:error, {:mismatch, :id, 1, 2}} = Segment.decode_footer(bytes, %{id: 1})
  end
end
