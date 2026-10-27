defmodule Tay.Storage.CRC32C do
  @moduledoc """
  Internal CRC-32C / Castagnoli implementation backed by a portable C NIF.

  Large updates run on dirty CPU schedulers. The C NIF is required;
  there is no automatic Elixir fallback.

  Reflected polynomial `0x82F63B78`, initial register and final XOR
  `0xFFFFFFFF`, no extra augmentation or final reflection. This is not IEEE
  CRC-32 and is not an authenticity or durability guarantee.

  `update/2` accepts an **unfinalized register**. To checksum chunks, start with
  `initial/0`, update in byte order, and finalize exactly once. The caller owns
  the wire byte order; this module returns an unsigned 32-bit integer.
  """

  import Bitwise
  @mask 0xFFFFFFFF
  @type register :: 0..0xFFFFFFFF

  @spec initial() :: register()
  def initial, do: @mask

  @spec checksum(binary()) :: register()
  def checksum(bytes) when is_binary(bytes), do: finalize(update(initial(), bytes))

  @doc "Returns finalized CRCs for the header and header followed by payload in one NIF call."
  @spec record_checksums(binary(), binary()) :: {register(), register()}
  def record_checksums(header, payload) when is_binary(header) and is_binary(payload),
    do: Tay.Storage.CRC32C.Native.record_checksums(header, payload)

  @spec update(register(), binary()) :: register()
  def update(register, bytes)
      when is_integer(register) and register >= 0 and register <= @mask and is_binary(bytes) do
    Tay.Storage.CRC32C.Native.update(register, bytes)
  end

  @spec finalize(register()) :: register()
  def finalize(register) when is_integer(register) and register >= 0 and register <= @mask,
    do: bxor(register, @mask)
end
