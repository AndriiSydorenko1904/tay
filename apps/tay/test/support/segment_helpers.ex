defmodule Tay.Test.SegmentHelpers do
  @moduledoc false
  alias Tay.Test.ReferenceCRC32C, as: CRC
  @dir Path.expand("../fixtures/storage/segment/v1", __DIR__)
  @store Base.decode16!("00112233445566778899AABBCCDDEEFF")
  def fixture(name), do: File.read!(Path.join(@dir, name))
  def store_id, do: @store

  def header(fields \\ []) do
    checked(
      <<"TAYS", Keyword.get(fields, :version, 1), Keyword.get(fields, :flags, 0),
        Keyword.get(fields, :reserved, 0)::16, Keyword.get(fields, :id, 1)::64,
        Keyword.get(fields, :first_sequence, 1)::64,
        Keyword.get(fields, :store_id, @store)::binary>>
    )
  end

  def footer(header, records, fields \\ []) do
    <<_::binary-size(8), id::64, first::64, store::binary-size(16), _::binary>> = header

    checked(
      <<"TAYF", Keyword.get(fields, :version, 1), Keyword.get(fields, :flags, 0),
        Keyword.get(fields, :reserved, 0)::16, Keyword.get(fields, :id, id)::64,
        Keyword.get(fields, :first_sequence, first)::64,
        Keyword.get(fields, :last_sequence, first + length(records) - 1)::64,
        Keyword.get(fields, :count, length(records))::64,
        Keyword.get(fields, :store_id, store)::binary,
        Keyword.get(fields, :segment_crc, CRC.checksum_chunks([header | records]))::32>>
    )
  end

  def checked(body), do: <<body::binary, CRC.checksum(body)::32>>
end
