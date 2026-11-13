defmodule Tay.Engine.CompactionConfig do
  @moduledoc "Validated retention and checkpoint policy; maintenance mechanics are internal."
  alias Tay.Storage.V2.Retention
  @max_timer 4_294_967_295
  @defaults %{automatic: true, terminal_retention: {:hours, 24}, checkpoint_interval: 0}

  def defaults, do: @defaults
  def new(false), do: {:ok, %{@defaults | automatic: false}}

  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- length(options) == length(Enum.uniq(Keyword.keys(options))),
         true <-
           Enum.all?(Keyword.keys(options), &(&1 in [:terminal_retention, :checkpoint_interval])),
         config <- Map.merge(@defaults, Map.new(options)),
         :ok <- Retention.validate(config.terminal_retention),
         true <- config.terminal_retention != :infinity,
         true <- Retention.persisted(config.terminal_retention) == config.terminal_retention,
         true <-
           is_integer(config.checkpoint_interval) and config.checkpoint_interval in 0..@max_timer do
      {:ok, config}
    else
      _ -> {:error, :compaction_configuration}
    end
  end

  def new(_), do: {:error, :compaction_configuration}
end
