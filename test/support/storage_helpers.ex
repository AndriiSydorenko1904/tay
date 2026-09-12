defmodule Tay.Test.ReferenceCRC32C do
  @moduledoc false
  import Bitwise

  # Independent test oracle: normal polynomial, left shifts, explicit reflection.
  # Unlike the production bit-by-bit right-shifting reference, this uses a table
  # so independently checking the 16 MiB boundary remains practical.
  @mask 0xFFFFFFFF
  @table List.to_tuple(
           for byte <- 0..255 do
             Enum.reduce(1..8, byte <<< 24, fn _, register ->
               shifted = register <<< 1 &&& @mask
               if (register &&& 0x80000000) == 0, do: shifted, else: bxor(shifted, 0x1EDC6F41)
             end)
           end
         )
  @reflected_bytes List.to_tuple(
                     for byte <- 0..255 do
                       Enum.reduce(0..7, 0, fn bit, acc ->
                         acc <<< 1 ||| (byte >>> bit &&& 1)
                       end)
                     end
                   )

  def checksum(bytes), do: checksum_chunks([bytes])

  def checksum_chunks(chunks) do
    register = Enum.reduce(chunks, @mask, &update(&2, &1))
    reflected = Enum.reduce(0..31, 0, fn bit, acc -> acc <<< 1 ||| (register >>> bit &&& 1) end)
    bxor(reflected, @mask)
  end

  defp update(register, <<>>), do: register

  defp update(register, <<byte, rest::binary>>) do
    index = bxor(register >>> 24, elem(@reflected_bytes, byte))
    update(bxor(register <<< 8 &&& @mask, elem(@table, index)), rest)
  end
end

defmodule Tay.Test.RecordHelpers do
  @moduledoc false
  import Bitwise
  alias Tay.Storage.Record
  alias Tay.Test.ReferenceCRC32C

  @fixture_dir Path.expand("../fixtures/storage/record/v1", __DIR__)
  @manifest_path Path.join(@fixture_dir, "manifest.exs")
  @external_resource @manifest_path
  {manifest, _binding} = Code.eval_file(@manifest_path)
  @fixtures manifest

  def fixtures, do: @fixtures
  def fixture(id), do: Enum.find(@fixtures, &(&1.id == id))
  def bytes(id), do: File.read!(Path.join(@fixture_dir, fixture(id).file))
  def expected(%{result: {:ok, fields, rest}}), do: {:ok, struct!(Record, fields), rest}
  def expected(%{result: result}), do: result

  def record(fields \\ []) do
    struct!(
      Record,
      Keyword.merge(
        [record_type: 1, payload_schema_version: 1, sequence: 1, payload: <<>>],
        fields
      )
    )
  end

  # Construct adversarial inputs without either production encoder or CRC code.
  # Explicitly permits invalid metadata and incomplete body lengths for tests.
  def frame(fields \\ []) do
    payload = Keyword.get(fields, :payload, <<>>)
    n = Keyword.get(fields, :payload_length, byte_size(payload))

    header =
      <<"TAY", 0, Keyword.get(fields, :format_version, 1), Keyword.get(fields, :record_type, 1),
        Keyword.get(fields, :flags, 0), Keyword.get(fields, :payload_schema_version, 1),
        Keyword.get(fields, :sequence, 1)::unsigned-big-64, n::unsigned-big-32>>

    header_crc = ReferenceCRC32C.checksum(header)
    record_crc = ReferenceCRC32C.checksum_chunks([header, payload])
    <<header::binary, header_crc::unsigned-big-32, payload::binary, record_crc::unsigned-big-32>>
  end

  def flip(bytes, offset, bit) do
    <<prefix::binary-size(^offset), byte, rest::binary>> = bytes
    <<prefix::binary, bxor(byte, 1 <<< bit), rest::binary>>
  end

  def incomplete(_record, available) when available < 24, do: {:incomplete, :header}

  def incomplete(record, available) do
    n = byte_size(record.payload)
    stage = if available < 24 + n, do: :payload, else: :checksum

    {:incomplete, stage,
     %{
       format_version: 1,
       record_type: record.record_type,
       flags: 0,
       payload_schema_version: record.payload_schema_version,
       sequence: record.sequence,
       payload_length: n,
       record_bytes: 28 + n,
       available_bytes: available,
       missing_bytes: 28 + n - available
     }}
  end
end
