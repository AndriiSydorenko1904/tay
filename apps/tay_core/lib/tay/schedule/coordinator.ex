defmodule Tay.Schedule.Coordinator do
  @moduledoc false
  use GenServer

  alias Tay.Core.API
  alias Tay.Protocol.JobOptions
  alias Tay.Schedule

  @call_timeout 5_000
  @retry_ms 1_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def register(server, fields), do: GenServer.call(server, {:register, fields}, @call_timeout)
  def cancel(server, id), do: GenServer.call(server, {:cancel, id}, @call_timeout)

  @impl true
  def init(%{core: core, schedules: durable}) when is_map(durable) do
    now = System.system_time(:millisecond)

    schedules =
      durable
      |> Map.values()
      |> Enum.reject(& &1.cancelled_at)
      |> Enum.reduce(%{}, fn stored, acc ->
        case Schedule.from_durable(stored) do
          {:ok, schedule} -> Map.put(acc, schedule.id, arm(schedule, schedule.options, now))
          _ -> acc
        end
      end)

    {:ok, %{core: core, schedules: schedules, operation: nil, operations: :queue.new()}}
  end

  @impl true
  def handle_call({:register, fields}, from, state) do
    id = Map.get(fields, "declaration_id") || identifier()
    now = System.system_time(:millisecond)

    with {:ok, schedule} <- Schedule.new(id, fields, now),
         options <- Map.get(fields, "options", %{}),
         {:ok, _} <- JobOptions.parse(options) do
      {:noreply, enqueue_operation(state, {:register, schedule, options, now, from})}
    else
      _ -> {:reply, {:error, "invalid_schedule"}, state}
    end
  end

  def handle_call({:cancel, id}, from, state),
    do: {:noreply, enqueue_operation(state, {:cancel, id, from})}

  @impl true
  def handle_info({:due, id, due}, state) do
    case Map.get(state.schedules, id) do
      %{schedule: %{next_at: ^due} = schedule, options: options} ->
        enqueue_occurrence(self(), state.core, schedule, options, due)
        entry = %{schedule: schedule, options: options, timer: nil}
        {:noreply, put_in(state.schedules[id], entry)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:enqueue_result, id, due, result}, state) do
    case Map.get(state.schedules, id) do
      %{schedule: %{next_at: ^due} = schedule, options: options} ->
        case result do
          :ok ->
            case Schedule.advance_after_delivery(schedule, due, System.system_time(:millisecond)) do
              {:ok, advanced} ->
                operation =
                  {:advance, schedule, advanced, options, due, System.system_time(:millisecond)}

                {:noreply, enqueue_operation(state, operation)}

              {:error, _} ->
                {:noreply, drop(state, id)}
            end

          :retry ->
            timer = Process.send_after(self(), {:due, id, due}, @retry_ms)
            entry = %{schedule: schedule, options: options, timer: timer}
            {:noreply, put_in(state.schedules[id], entry)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:operation_result, token, result}, %{operation: {token, operation}} = state) do
    next = complete_operation(state, operation, result)
    {:noreply, continue_operations(%{next | operation: nil})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp arm(schedule, options, now) do
    delay = max(schedule.next_at - now, 0)
    timer = Process.send_after(self(), {:due, schedule.id, schedule.next_at}, delay)
    %{schedule: schedule, options: options, timer: timer}
  end

  defp enqueue_operation(state, operation),
    do: continue_operations(%{state | operations: :queue.in(operation, state.operations)})

  defp continue_operations(%{operation: nil} = state) do
    case :queue.out(state.operations) do
      {{:value, operation}, remaining} ->
        begin_operation(%{state | operations: remaining}, operation)

      {:empty, _} ->
        state
    end
  end

  defp continue_operations(state), do: state

  defp begin_operation(state, {:register, schedule, options, _now, from} = operation) do
    case Map.get(state.schedules, schedule.id) do
      %{schedule: existing, options: ^options} = entry ->
        if Schedule.equivalent?(existing, schedule) do
          GenServer.reply(from, {:ok, public_schedule(entry.schedule)})
          continue_operations(state)
        else
          launch(state, operation)
        end

      _ ->
        launch(state, operation)
    end
  end

  defp begin_operation(state, {:cancel, id, from}) do
    case Map.fetch(state.schedules, id) do
      {:ok, %{schedule: schedule}} ->
        launch(state, {:cancel, schedule, from})

      :error ->
        GenServer.reply(from, {:error, "schedule_not_found"})
        continue_operations(state)
    end
  end

  defp begin_operation(state, {:advance, schedule, _advanced, _options, due, _now} = operation) do
    case Map.get(state.schedules, schedule.id) do
      %{schedule: %{revision: revision, next_at: ^due}} when revision == schedule.revision ->
        launch(state, operation)

      _ ->
        continue_operations(state)
    end
  end

  defp launch(state, operation) do
    owner = self()
    token = make_ref()
    Task.start(fn -> send(owner, {:operation_result, token, run(operation, state.core)}) end)
    %{state | operation: {token, operation}}
  end

  defp run({:register, schedule, _, _, _}, core),
    do: API.call(core, :register_schedule, [schedule])

  defp run({:cancel, schedule, _}, core),
    do: API.call(core, :cancel_schedule, [schedule.id, schedule.revision])

  defp run({:advance, schedule, advanced, _, due, now}, core),
    do:
      API.call(core, :advance_schedule, [
        schedule.id,
        schedule.revision,
        due,
        advanced.next_at,
        now
      ])

  defp complete_operation(state, {:register, schedule, options, now, from}, {:ok, stored}) do
    schedule = durable(schedule, stored)
    next = drop(state, schedule.id)
    GenServer.reply(from, {:ok, public_schedule(schedule)})
    %{next | schedules: Map.put(next.schedules, schedule.id, arm(schedule, options, now))}
  end

  defp complete_operation(state, {:register, schedule, _, _, from}, error) do
    GenServer.reply(from, operation_error(error))
    if unknown?(error), do: drop(state, schedule.id), else: state
  end

  defp complete_operation(state, {:cancel, schedule, from}, {:ok, stored}) do
    GenServer.reply(from, {:ok, public_schedule(durable(schedule, stored))})
    drop(state, schedule.id)
  end

  defp complete_operation(state, {:cancel, schedule, from}, error) do
    GenServer.reply(from, operation_error(error))
    if unknown?(error), do: drop(state, schedule.id), else: state
  end

  defp complete_operation(state, {:advance, schedule, advanced, options, _, now}, {:ok, stored}) do
    advanced = durable(advanced, stored)
    %{state | schedules: Map.put(state.schedules, schedule.id, arm(advanced, options, now))}
  end

  defp complete_operation(state, {:advance, schedule, _, options, due, _}, error) do
    cond do
      unknown?(error) ->
        drop(state, schedule.id)

      retryable?(error) ->
        timer = Process.send_after(self(), {:due, schedule.id, due}, @retry_ms)
        entry = %{schedule: schedule, options: options, timer: timer}
        put_in(state.schedules[schedule.id], entry)

      true ->
        drop(state, schedule.id)
    end
  end

  defp durable(schedule, stored) do
    %{
      schedule
      | revision: stored.revision,
        next_at: stored.next_at,
        last_at: stored.last_at,
        cancelled_at: stored.cancelled_at
    }
  end

  defp operation_error({:error, %Tay.Error{kind: :unknown_outcome, reason: reason}}),
    do: {:error, "unknown_outcome", %{"reason" => unknown_reason(reason)}}

  defp operation_error({:error, %Tay.Error{kind: :capacity, reason: reason}}),
    do: {:error, "capacity", %{"reason" => atom_reason(reason, "capacity_exhausted")}}

  defp operation_error({:error, %Tay.Error{kind: :unavailable}}), do: {:error, "unavailable"}
  defp operation_error({:error, %Tay.Error{kind: :conflict}}), do: {:error, "schedule_conflict"}
  defp operation_error(_), do: {:error, "invalid_schedule"}

  defp unknown?({:error, %Tay.Error{kind: :unknown_outcome}}), do: true
  defp unknown?(_), do: false

  defp retryable?({:error, %Tay.Error{kind: kind}}) when kind in [:capacity, :unavailable],
    do: true

  defp retryable?(_), do: false

  defp drop(state, id) do
    case Map.pop(state.schedules, id) do
      {nil, _} ->
        state

      {%{timer: timer}, schedules} ->
        if timer, do: Process.cancel_timer(timer)
        %{state | schedules: schedules}
    end
  end

  defp enqueue_occurrence(owner, core, schedule, raw_options, due) do
    Task.start(fn ->
      result =
        with {:ok, options} <- JobOptions.parse(raw_options),
             id <- occurrence_id(schedule.id, due),
             options <- Keyword.put(options, :id, id) do
          case API.call(core, :enqueue, [schedule.task, schedule.args, options]) do
            {:ok, _} -> :ok
            _ -> if match?({:ok, _}, API.call(core, :get_job, [id])), do: :ok, else: :retry
          end
        else
          _ -> :retry
        end

      send(owner, {:enqueue_result, schedule.id, due, result})
    end)
  end

  defp occurrence_id(id, due) do
    digest =
      :crypto.hash(:sha256, ["tay-schedule-occurrence-v1:", id, ":", Integer.to_string(due)])

    raw = binary_part(digest, 0, 16)
    Tay.JobID.encode(if raw == <<0::128>>, do: <<0::120, 1>>, else: raw)
  end

  defp public_schedule(schedule) do
    %{
      "id" => schedule.id,
      "task" => schedule.task,
      "kind" => Atom.to_string(schedule.kind),
      "timezone" => schedule.timezone,
      "overlap" => schedule.overlap,
      "catch_up" => schedule.catch_up,
      "next_at" => schedule.next_at,
      "last_at" => schedule.last_at,
      "cancelled_at" => schedule.cancelled_at,
      "revision" => schedule.revision
    }
  end

  defp atom_reason(reason, _) when is_atom(reason), do: Atom.to_string(reason)
  defp atom_reason(_, fallback), do: fallback
  defp unknown_reason(:submitted_request_lost), do: "caller_timeout_or_disconnect"
  defp unknown_reason({:generation_lost, _}), do: "generation_lost"
  defp unknown_reason(_), do: "outcome_unknown"
  defp identifier, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
end
