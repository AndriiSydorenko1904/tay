defmodule Tay.Engine.CompactionEvents do
  @moduledoc "Bounded, payload-free structured compaction events emitted through Logger."
  require Logger

  @events [
    :evaluation_performed,
    :evaluation_skipped,
    :compaction_eligible,
    :compaction_deferred,
    :automatic_compaction_started,
    :automatic_compaction_completed,
    :automatic_compaction_failed
  ]
  @reasons [
    :eligible,
    :evaluated,
    :completed,
    :not_enough_reclaimable_bytes,
    :ratio_below_threshold,
    :cooldown,
    :too_few_segments,
    :active_jobs_present,
    :busy,
    :draining,
    :drained,
    :stopping,
    :stopped,
    :recovering,
    :insufficient_headroom,
    :unhealthy,
    :estimate_unavailable,
    :source_changed,
    :unable_to_drain,
    :publication_failed,
    :unknown_outcome,
    :below_minimum_benefit
  ]
  @fields [
    :sealed_bytes,
    :sealed_segments,
    :candidate_upper_bytes,
    :reclaimable_bytes,
    :expired_terminals,
    :ratio,
    :evaluation_us,
    :source_bytes,
    :candidate_bytes,
    :reclaimed_bytes,
    :pause_ms,
    :peak_writer_process_bytes,
    :expired_jobs,
    :retained_terminal_jobs
  ]

  def normalize(event, reason, measurements) when event in @events do
    measurements = Map.take(measurements, @fields)

    measurements =
      Map.filter(measurements, fn {_, v} ->
        is_number(v) and v >= 0 and v <= 18_446_744_073_709_551_615
      end)

    Map.merge(measurements, %{
      event: event,
      reason: if(reason in @reasons, do: reason, else: :publication_failed)
    })
  end

  def emit(event, reason, measurements \\ %{}) do
    data = normalize(event, reason, measurements)
    Logger.debug("Tay compaction", tay_compaction: data)
    :ok
  end

  def result({:ok, stats}), do: {:ok, Map.take(stats, @fields)}
  def result({:deferred, reason}) when reason in @reasons, do: {:deferred, reason}
  def result({:deferred, _}), do: {:error, :publication_failed}
  def result({:error, reason}) when reason in @reasons, do: {:error, reason}
  def result({:error, %Tay.Error{kind: :timeout}}), do: {:deferred, :unable_to_drain}

  def result(
        {:error, %Tay.Error{reason: {:compaction_failed, {:uncertain, :insufficient_headroom}}}}
      ),
      do: {:deferred, :insufficient_headroom}

  def result({:error, %Tay.Error{reason: {:compaction_failed, :compaction_source_changed}}}),
    do: {:deferred, :source_changed}

  def result({:error, %Tay.Error{kind: :unknown_outcome}}), do: {:error, :unknown_outcome}
  def result({:error, _}), do: {:error, :publication_failed}
end
