defmodule Tay.Engine.CompactionPolicy do
  @moduledoc """
  One per-Engine asynchronous evaluator. It owns no storage capability and never
  replays history. A single tokenized timer is rearmed only after a result; a
  generation notification invalidates an outstanding estimate, not a publication.
  """
  use GenServer
  alias Tay.Engine.CompactionEvents, as: Events
  alias Tay.Execution.Clock

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  def child_spec(config),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, shutdown: :infinity}

  def init(config) do
    Process.flag(:trap_exit, true)
    guardian = Process.whereis(config.name)
    :ok = GenServer.call(guardian, {:attach_policy, self()})

    {:ok,
     schedule(%{
       guardian: guardian,
       config: config.compaction,
       clock: config.clock,
       timer: nil,
       pending: nil,
       last_result: nil,
       started: nil
     })}
  end

  def eligible(summary, config, now) do
    cond do
      not is_nil(summary.last_compaction_at) and
          now - summary.last_compaction_at < config.min_interval ->
        {:error, :cooldown}

      summary.sealed_segments < config.min_sealed_segments ->
        {:error, :too_few_segments}

      summary.reclaimable_bytes < config.min_reclaimable_bytes ->
        {:error, :not_enough_reclaimable_bytes}

      summary.ratio < config.dead_ratio_threshold ->
        {:error, :ratio_below_threshold}

      summary.reclaimable_bytes <= 0 ->
        {:error, :below_minimum_benefit}

      true ->
        :ok
    end
  end

  def handle_info({:evaluate, token}, %{timer: {timer, token}, pending: nil} = s) do
    Process.cancel_timer(timer)
    request = make_ref()
    GenServer.cast(s.guardian, {:policy_evaluate, self(), request})

    {:noreply,
     %{
       s
       | timer: nil,
         pending: {:estimate, request},
         started: System.monotonic_time(:microsecond)
     }}
  end

  def handle_info({:policy_estimate, token, {:ok, summary}}, %{pending: {:estimate, token}} = s) do
    elapsed = System.monotonic_time(:microsecond) - s.started

    Events.emit(
      :evaluation_performed,
      :evaluated,
      Map.put(summary, :evaluation_us, elapsed)
    )

    case eligible(summary, s.config, Clock.wall(s.clock)) do
      :ok ->
        Events.emit(:compaction_eligible, :eligible, summary)

        GenServer.cast(
          s.guardian,
          {:automatic_compaction, self(), token, summary.generation, summary.source}
        )

        {:noreply, %{s | pending: {:operation, token}}}

      {:error, reason} ->
        Events.emit(:evaluation_skipped, reason, summary)
        {:noreply, schedule(%{s | pending: nil})}
    end
  end

  def handle_info({:policy_estimate, token, {:error, reason}}, %{pending: {:estimate, token}} = s) do
    Events.emit(:compaction_deferred, reason)
    {:noreply, schedule(%{s | pending: nil, last_result: {:deferred, reason}})}
  end

  def handle_info({{:compaction_policy, token}, result}, %{pending: {:operation, token}} = s) do
    result = Events.result(result)

    case result do
      {:ok, stats} -> Events.emit(:automatic_compaction_completed, :completed, stats)
      {:deferred, reason} -> Events.emit(:compaction_deferred, reason)
      {:error, reason} -> Events.emit(:automatic_compaction_failed, reason)
    end

    {:noreply, schedule(%{s | pending: nil, last_result: result})}
  end

  def handle_info(
        {:policy_generation, guardian},
        %{guardian: guardian, pending: {:estimate, _}} = s
      ),
      do: {:noreply, schedule(%{s | pending: nil})}

  def handle_info({:policy_generation, guardian}, %{guardian: guardian} = s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s) do
    if s.timer, do: Process.cancel_timer(elem(s.timer, 0))

    try do
      GenServer.call(s.guardian, :policy_shutdown, :infinity)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp schedule(s) do
    if s.timer, do: Process.cancel_timer(elem(s.timer, 0))
    token = make_ref()
    timer = Process.send_after(self(), {:evaluate, token}, s.config.check_interval)
    %{s | timer: {timer, token}, started: nil}
  end

  def format_status(status), do: Map.put(status, :state, :private_compaction_policy)
end
