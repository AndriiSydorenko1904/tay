defmodule Tay.Engine.CompactionConfig do
  @moduledoc "Finite validated automatic compaction policy."
  alias Tay.Storage.V2.Retention
  @max_timer 4_294_967_295
  @max_time 9_223_372_036_854_775_807
  @defaults %{
    enabled: true,
    terminal_retention: {:hours, 24},
    check_interval: 60_000,
    min_interval: 3_600_000,
    min_sealed_segments: 1,
    min_reclaimable_bytes: 16_777_216,
    dead_ratio_threshold: 0.25
  }

  def defaults, do: @defaults
  def new(false), do: {:ok, %{@defaults | enabled: false}}

  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- length(options) == length(Enum.uniq(Keyword.keys(options))),
         true <- Enum.all?(Keyword.keys(options), &Map.has_key?(@defaults, &1)),
         config <- Map.merge(@defaults, Map.new(options)),
         true <- is_boolean(config.enabled),
         :ok <- Retention.validate(config.terminal_retention),
         true <- config.terminal_retention != :infinity,
         true <- timer?(config.check_interval) and timer?(config.min_interval),
         true <-
           is_integer(config.min_sealed_segments) and
             config.min_sealed_segments in 1..4_294_967_295,
         true <-
           is_integer(config.min_reclaimable_bytes) and
             config.min_reclaimable_bytes in 1..@max_time,
         true <-
           is_number(config.dead_ratio_threshold) and
             config.dead_ratio_threshold > 0 and config.dead_ratio_threshold <= 1 do
      {:ok, config}
    else
      _ -> {:error, :compaction_configuration}
    end
  end

  def new(_), do: {:error, :compaction_configuration}
  defp timer?(n), do: is_integer(n) and n in 1..@max_timer
end
