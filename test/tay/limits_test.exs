defmodule Tay.LimitsTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Tay.Limits

  test "names the fixed-width and payload format boundaries" do
    assert Limits.int64_min() == -(1 <<< 63)
    assert Limits.int64_max() == (1 <<< 63) - 1
    assert Limits.uint32_max() == (1 <<< 32) - 1
    assert Limits.uint64_max() == (1 <<< 64) - 1
    assert Limits.max_payload_bytes() == 16 * 1_024 * 1_024
  end
end
