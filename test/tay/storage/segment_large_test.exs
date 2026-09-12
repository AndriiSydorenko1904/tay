defmodule Tay.Storage.SegmentLargeTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias Tay.Storage.Segment
  alias Tay.Test.{RecordHelpers, SegmentHelpers}
  @moduletag :large_segment
  @moduletag timeout: 300_000
  if System.get_env("TAY_LARGE_SEGMENT_TEST") != "1" do
    @moduletag skip: "run explicitly with TAY_LARGE_SEGMENT_TEST=1"
  end

  @frame 16_777_244
  @file_bytes 1_073_741_824
  @footer @file_bytes - 64
  @mask 0xFFFFFFFF
  @table List.to_tuple(
           for byte <- 0..255 do
             Enum.reduce(1..8, byte <<< 24, fn _, r ->
               shifted = r <<< 1 &&& @mask
               if (r &&& 0x80000000) == 0, do: shifted, else: bxor(shifted, 0x1EDC6F41)
             end)
           end
         )
  @reflected List.to_tuple(
               for byte <- 0..255 do
                 Enum.reduce(0..7, 0, fn bit, acc -> acc <<< 1 ||| (byte >>> bit &&& 1) end)
               end
             )

  test "exactly 1 GiB sealed geometry streams with one lazy record buffer" do
    key = make_ref()
    header = SegmentHelpers.header()
    payload = :binary.copy(<<7>>, 16_777_216)
    Process.put(key, %{cache: nil, consumed: 0, crc: @mask, largest: 0})

    read = fn offset, length ->
      assert length <= @frame
      state = Process.get(key)

      {bytes, cache} =
        cond do
          offset < 44 ->
            {binary_part(header, offset, length), state.cache}

          offset >= @footer ->
            footer =
              SegmentHelpers.footer(header, [],
                count: 64,
                last_sequence: 64,
                segment_crc: final(state.crc)
              )

            {binary_part(footer, offset - @footer, length), state.cache}

          true ->
            index = div(offset - 44, @frame)

            frame =
              case state.cache do
                {^index, frame} ->
                  frame

                _ ->
                  n = if index == 63, do: @footer - 44 - 63 * @frame - 28, else: 16_777_216
                  RecordHelpers.frame(sequence: index + 1, payload: binary_part(payload, 0, n))
              end

            {binary_part(frame, offset - 44 - index * @frame, length), {index, frame}}
        end

      ending = min(offset + length, @footer)
      assert offset <= state.consumed or offset >= @footer

      crc =
        if ending > state.consumed do
          update(state.crc, binary_part(bytes, state.consumed - offset, ending - state.consumed))
        else
          state.crc
        end

      Process.put(key, %{
        cache: cache,
        consumed: max(state.consumed, ending),
        crc: crc,
        largest: max(state.largest, length)
      })

      {:ok, bytes}
    end

    try do
      assert {:ok, %{state: :sealed, count: 64, last_sequence: 64, bytes: @file_bytes}} =
               Segment.scan(read, @file_bytes)

      assert Process.get(key).largest == @frame
      assert Process.get(key).consumed == @footer
    after
      Process.delete(key)
    end
  end

  # Independent normal-polynomial streaming oracle (production is reflected).
  defp update(r, <<>>), do: r

  defp update(r, <<byte, rest::binary>>) do
    index = bxor(r >>> 24, elem(@reflected, byte))
    update(bxor(r <<< 8 &&& @mask, elem(@table, index)), rest)
  end

  defp final(r),
    do: bxor(Enum.reduce(0..31, 0, fn bit, acc -> acc <<< 1 ||| (r >>> bit &&& 1) end), @mask)
end
