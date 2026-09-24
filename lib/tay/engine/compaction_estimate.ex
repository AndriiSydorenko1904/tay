defmodule Tay.Engine.CompactionEstimate do
  @moduledoc """
  Conservative volatile policy accounting; never filesystem authority or free space.
  At most 128 oldest hourly terminal buckets survive. Discarding contributions
  only reduces known expiry and thus increases the candidate upper bound.
  """
  alias Tay.Event.V1
  alias Tay.Storage.V2.Retention
  @terminal [:completed, :cancelled, :discarded]
  @bucket_ms 3_600_000
  @max_buckets 128

  def new,
    do: %{
      jobs: 0,
      definition_bytes: 0,
      terminal_jobs: 0,
      terminal_bytes: 0,
      buckets: %{},
      available: true
    }

  def terminal_time(job, at), do: if(job.state in @terminal, do: at, else: nil)

  # Prefix<=41, body header=5, keys=174, state<=14, scalars<=72,
  # diagnostic<=45, Record=28, per-job segment framing=108: total<=487.
  def job_bound(job), do: byte_size(job.definition_bytes) + 512

  def replace(estimate, previous, job) do
    estimate = if previous, do: bucket(estimate, previous, -1), else: estimate

    estimate = %{
      estimate
      | jobs: estimate.jobs + if(previous, do: 0, else: 1),
        definition_bytes:
          estimate.definition_bytes + if(previous, do: 0, else: byte_size(job.definition_bytes))
    }

    bucket(estimate, job, 1)
  end

  defp bucket(estimate, %{state: state} = job, sign) when state in @terminal do
    at = Map.get(job, :terminal_at)

    if V1.time?(at) do
      key = div(at, @bucket_ms)
      old = Map.get(estimate.buckets, key, %{count: 0, bytes: 0})
      next = %{count: max(0, old.count + sign), bytes: max(0, old.bytes + sign * job_bound(job))}

      buckets =
        if next.count == 0,
          do: Map.delete(estimate.buckets, key),
          else: Map.put(estimate.buckets, key, next)

      buckets =
        if map_size(buckets) > @max_buckets,
          do: Map.delete(buckets, Enum.max(Map.keys(buckets))),
          else: buckets

      %{
        estimate
        | buckets: buckets,
          terminal_jobs: max(0, estimate.terminal_jobs + sign),
          terminal_bytes: max(0, estimate.terminal_bytes + sign * job_bound(job))
      }
    else
      %{estimate | available: false}
    end
  end

  defp bucket(estimate, _, _), do: estimate

  def summarize(estimate, sealed_bytes, sealed_segments, retention, now),
    do: summarize(estimate, sealed_bytes, sealed_segments, retention, :infinity, now)

  def summarize(estimate, sealed_bytes, sealed_segments, retention, max_terminal_jobs, now) do
    with true <- estimate.available,
         {:ok, duration} <- Retention.duration(retention),
         true <- V1.time?(now) do
      cutoff = now - duration

      {expired, expired_bound} =
        Enum.reduce(estimate.buckets, {0, 0}, fn {hour, bucket}, {count, bytes} ->
          if (hour + 1) * @bucket_ms - 1 <= cutoff,
            do: {count + bucket.count, bytes + bucket.bytes},
            else: {count, bytes}
        end)

      pressure_jobs =
        if max_terminal_jobs == :infinity,
          do: 0,
          else: max(estimate.terminal_jobs - max_terminal_jobs, 0)

      pressure_bound =
        if estimate.terminal_jobs == 0,
          do: 0,
          else: div(estimate.terminal_bytes * pressure_jobs, estimate.terminal_jobs)

      removed_bound = max(expired_bound, pressure_bound)
      removed_jobs = max(expired, pressure_jobs)
      snapshot_bound = estimate.definition_bytes + estimate.jobs * 512 - removed_bound
      # Manifest entries<=256 each; 1 MiB covers fixed metadata and empty tail.
      candidate_bound =
        snapshot_bound + 1_048_576 +
          (sealed_segments + estimate.jobs - removed_jobs) * 256

      reclaimable = max(0, sealed_bytes - candidate_bound)

      {:ok,
       %{
         sealed_bytes: sealed_bytes,
         sealed_segments: sealed_segments,
         candidate_upper_bytes: candidate_bound,
         reclaimable_bytes: reclaimable,
         expired_terminals: expired,
         terminal_jobs: estimate.terminal_jobs,
         terminal_pressure: pressure_jobs > 0,
         excess_terminal_jobs: pressure_jobs,
         ratio: if(sealed_bytes == 0, do: 0.0, else: reclaimable / sealed_bytes)
       }}
    else
      _ -> {:error, :estimate_unavailable}
    end
  end
end
