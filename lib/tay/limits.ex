defmodule Tay.Limits do
  @moduledoc false

  @int64_min -0x8000000000000000
  @int64_max 0x7FFFFFFFFFFFFFFF
  @uint32_max 0xFFFFFFFF
  @uint64_max 0xFFFFFFFFFFFFFFFF
  @max_payload_bytes 16 * 1_024 * 1_024

  @type int64 :: -0x8000000000000000..0x7FFFFFFFFFFFFFFF
  @type uint32 :: 0..0xFFFFFFFF
  @type uint64 :: 0..0xFFFFFFFFFFFFFFFF
  @type positive_uint64 :: 1..0xFFFFFFFFFFFFFFFF
  @type max_payload_bytes :: 0x1000000
  @type payload_size :: 0..0x1000000

  @spec int64_min() :: neg_integer()
  def int64_min, do: @int64_min

  @spec int64_max() :: pos_integer()
  def int64_max, do: @int64_max

  @spec uint32_max() :: pos_integer()
  def uint32_max, do: @uint32_max

  @spec uint64_max() :: pos_integer()
  def uint64_max, do: @uint64_max

  @spec max_payload_bytes() :: max_payload_bytes()
  def max_payload_bytes, do: @max_payload_bytes
end
