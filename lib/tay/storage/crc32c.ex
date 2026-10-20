defmodule Tay.Storage.CRC32C do
  @moduledoc """
  Internal, pure reference CRC-32C / Castagnoli implementation.

  Reflected polynomial `0x82F63B78`, initial register and final XOR
  `0xFFFFFFFF`, no extra augmentation or final reflection. This is not IEEE
  CRC-32 and is not an authenticity or durability guarantee.

  `update/2` accepts an **unfinalized register**. To checksum chunks, start with
  `initial/0`, update in byte order, and finalize exactly once. The caller owns
  the wire byte order; this module returns an unsigned 32-bit integer.
  """

  import Bitwise

  @polynomial 0x82F63B78
  @mask 0xFFFFFFFF
  @table List.to_tuple(
           for byte <- 0..255 do
             Enum.reduce(1..8, byte, fn _, register ->
               shifted = register >>> 1
               if (register &&& 1) == 1, do: bxor(shifted, @polynomial), else: shifted
             end)
           end
         )
  @type register :: 0..0xFFFFFFFF

  @spec initial() :: register()
  def initial, do: @mask

  @spec checksum(binary()) :: register()
  def checksum(bytes) when is_binary(bytes), do: finalize(update(initial(), bytes))

  @spec update(register(), binary()) :: register()
  def update(register, bytes)
      when is_integer(register) and register >= 0 and register <= @mask and is_binary(bytes) do
    update_bytes(register, bytes)
  end

  @spec finalize(register()) :: register()
  def finalize(register) when is_integer(register) and register >= 0 and register <= @mask,
    do: bxor(register, @mask)

  defp update_bytes(register, <<a, b, c, d, e, f, g, h, rest::binary>>) do
    register = step(register, a)
    register = step(register, b)
    register = step(register, c)
    register = step(register, d)
    register = step(register, e)
    register = step(register, f)
    register = step(register, g)
    register = step(register, h)
    update_bytes(register, rest)
  end

  defp update_bytes(register, <<byte, rest::binary>>),
    do: update_bytes(step(register, byte), rest)

  defp update_bytes(register, <<>>), do: register

  defp step(register, byte),
    do: bxor(register >>> 8, elem(@table, bxor(register, byte) &&& 0xFF))
end
