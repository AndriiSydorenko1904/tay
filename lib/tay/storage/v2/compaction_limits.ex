defmodule Tay.Storage.V2.CompactionLimits do
  @moduledoc false

  @catch_up_target_events 1_024
  @catch_up_target_bytes 1_048_576
  @catch_up_max_rounds 64
  @max_delta_events 65_536
  @max_delta_bytes 67_108_864

  @spec catch_up_target_events() :: pos_integer()
  def catch_up_target_events, do: @catch_up_target_events
  @spec catch_up_target_bytes() :: pos_integer()
  def catch_up_target_bytes, do: @catch_up_target_bytes
  @spec catch_up_max_rounds() :: pos_integer()
  def catch_up_max_rounds, do: @catch_up_max_rounds
  @spec max_delta_events() :: pos_integer()
  def max_delta_events, do: @max_delta_events
  @spec max_delta_bytes() :: pos_integer()
  def max_delta_bytes, do: @max_delta_bytes
end
