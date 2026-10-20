defmodule Tay.Engine.GroupCommit do
  @moduledoc false

  alias Tay.Engine.ProjectionState
  alias Tay.Storage.Writer

  def batchable?(state, {:insert, _, _, _, requested}) do
    mode = requested || state.config.job_durability
    enabled?(state) and mode == :persistent
  end

  def batchable?(state, {operation, id, _revision}) when operation in [:cancel, :retry] do
    case ProjectionState.lookup(state, id) do
      nil -> false
      job -> enabled?(state) and ProjectionState.durability(state, job) == :persistent
    end
  end

  def batchable?(state, {operation, _, _, _, _, _}) when operation == :advance_schedule,
    do: enabled?(state)

  def batchable?(state, {operation, _, _, _}) when operation == :cancel_schedule,
    do: enabled?(state)

  def batchable?(state, {:register_schedule, _}), do: enabled?(state)

  def batchable?(_, _), do: false

  defp enabled?(state) do
    batch = state.config.journal_batch

    state.config.durability == :sync and state.mode == :ready and
      (batch.max_events > 1 or batch.interval_ms > 0)
  end

  def full?(%{group_commit: %{commands: commands}, config: %{journal_batch: batch}}),
    do: length(commands) >= batch.max_events

  def full?(_), do: false

  def enqueue(%{group_commit: nil} = state, permit, intent, from) do
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:flush_group_commit, token},
        state.config.journal_batch.interval_ms
      )

    %{
      state
      | group_commit: %{
          token: token,
          timer: timer,
          started: System.monotonic_time(),
          commands: [{permit, intent, from}]
        }
    }
  end

  def enqueue(state, permit, intent, from) do
    update_in(state.group_commit.commands, &[{permit, intent, from} | &1])
  end

  def flush(%{group_commit: nil} = state, _command, _reply, _complete_drains), do: state

  def flush(state, command, reply, complete_drains) do
    group = state.group_commit
    Process.cancel_timer(group.timer)
    wait = System.monotonic_time() - group.started
    :ok = Writer.begin_group_commit(state.writer, state.admission)
    initial = %{state | group_commit: nil, deferred_transitions: []}

    {next, replies} =
      Enum.reduce(Enum.reverse(group.commands), {initial, []}, fn
        {permit, intent, from}, {acc, replies} ->
          {result, acc} = command.(intent, acc)
          {acc, [{permit, from, result} | replies]}
      end)

    case Writer.finish_group_commit(next.writer, next.admission) do
      {:ok, %{size: size, fsync_duration: fsync_duration}} ->
        Tay.Telemetry.group_commit(next.config.name, size, wait, fsync_duration)
        emit_deferred_transitions(next)
        next = %{next | deferred_transitions: nil}

        Enum.each(Enum.reverse(replies), fn {permit, from, result} ->
          reply.(next, permit, from, result)
        end)

        complete_drains.(next)

      _ ->
        exit(:writer_commit_unknown)
    end
  end

  defp emit_deferred_transitions(state) do
    state.deferred_transitions
    |> Enum.reverse()
    |> Enum.each(fn {operation, previous, job} ->
      Tay.Telemetry.transition(state.config.name, operation, previous, job)
    end)
  end
end
