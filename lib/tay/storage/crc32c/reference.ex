defmodule Tay.Storage.CRC32C.Reference do
  @moduledoc false
  # Historical Elixir implementation, retained for benchmarks and differential checks.
  # The running storage engine uses the C NIF, never this module.
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
