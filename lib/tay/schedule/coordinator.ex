defmodule Tay.Schedule.Coordinator do
  @moduledoc false
  use GenServer

  alias Tay.Core.API
  alias Tay.Protocol.JobOptions
  alias Tay.Schedule

  @call_timeout 5_000
  @retry_ms 1_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def register(server, fields) when is_map(fields) do
    now = System.system_time(:millisecond)
    id = Map.get(fields, "declaration_id") || identifier()
    options = Map.get(fields, "options", %{})

    with {:ok, schedule} <- Schedule.new(id, fields, now),
         {:ok, _} <- JobOptions.parse(options),
         do: request(server, {:register_prepared, schedule, options, now}),
         else: (_ -> {:error, "invalid_schedule"})
  end

  def register(_, _), do: {:error, "invalid_schedule"}
  def cancel(server, id), do: request(server, {:cancel, id})

  defp request(server, payload) do
    with {:ok, engine} <- GenServer.call(server, :admission_context, @call_timeout),
         {:ok, meta} <- Tay.Engine.Admission.metadata(engine) do
      case Tay.Engine.Admission.request(
             engine,
             meta,
             {:schedule_operation, server, payload},
             Tay.State.Memory.bytes(payload),
             :schedule_operation,
             nil,
             @call_timeout
           ) do
        {:error, %Tay.Error{kind: :capacity, reason: reason}} ->
          {:error, "capacity", %{"reason" => inspect(reason)}}

        {:error, %Tay.Error{kind: :unknown_outcome}} ->
          {:error, "unknown_outcome", %{"reason" => "caller_timeout_or_disconnect"}}

        {:error, %Tay.Error{}} ->
          {:error, "unavailable"}

        value ->
          value
      end
    else
      _ -> {:error, "unavailable"}
    end
  end

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

    {:ok,
     %{
       core: core,
       schedules: schedules,
       operation: nil,
       operation_monitor: nil,
       operations: :queue.new()
     }}
  end

  @impl true
  def handle_call(:admission_context, _from, %{core: {Tay.Core.Local, engine}} = state),
    do: {:reply, {:ok, engine}, state}

  def handle_call({:register_prepared, schedule, options, now}, from, state),
    do: {:noreply, enqueue_operation(state, {:register, schedule, options, now, from})}

  def handle_call({:cancel, id}, from, state),
    do: {:noreply, enqueue_operation(state, {:cancel, id, from})}

  @impl true
  def handle_info({:admitted, guardian, engine, _generation, permit, payload, from}, state) do
    admitted = {:admitted, guardian, engine, permit, from}

    case handle_call(payload, admitted, state) do
      {:reply, result, next} ->
        reply(admitted, result)
        {:noreply, next}

      {:noreply, next} ->
        {:noreply, next}
    end
  end

  def handle_info({:due, id, due}, state) do
    case Map.get(state.schedules, id) do
      %{schedule: %{next_at: ^due} = schedule, options: options} ->
        now = System.system_time(:millisecond)

        if now < due do
          {:noreply, put_in(state.schedules[id], arm(schedule, options, now))}
        else
          case Schedule.advance_after_delivery(schedule, due, now) do
            {:ok, advanced} ->
              entry = %{schedule: schedule, options: options, timer: nil}
              state = put_in(state.schedules[id], entry)

              {:noreply,
               enqueue_operation(state, {:deliver, schedule, advanced, options, due, now})}

            {:error, _} ->
              {:noreply, drop(state, id)}
          end
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:operation_result, token, result}, %{operation: {token, operation}} = state) do
    Process.demonitor(state.operation_monitor, [:flush])
    next = complete_operation(state, operation, result)
    {:noreply, continue_operations(%{next | operation: nil, operation_monitor: nil})}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{operation_monitor: monitor, operation: {_token, operation}} = state
      ) do
    error = {:error, Tay.Error.new(:unknown_outcome, :schedule_operation_lost)}
    next = complete_operation(state, operation, error)
    {:noreply, continue_operations(%{next | operation: nil, operation_monitor: nil})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp arm(schedule, options, _now) do
    delay = max(schedule.next_at - System.system_time(:millisecond), 0)

    timer =
      Process.send_after(self(), {:due, schedule.id, schedule.next_at}, min(delay, 4_294_967_295))

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
          reply(from, {:ok, public_schedule(entry.schedule)})
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
        reply(from, {:error, "schedule_not_found"})
        continue_operations(state)
    end
  end

  defp begin_operation(state, {:deliver, schedule, _advanced, _options, due, _now} = operation) do
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
    core = state.core

    {_pid, monitor} =
      spawn_monitor(fn ->
        send(owner, {:operation_result, token, run(operation, core)})
      end)

    %{state | operation: {token, operation}, operation_monitor: monitor}
  end

  defp run({:register, schedule, _, _, _}, core),
    do: API.call(core, :register_schedule, [schedule])

  defp run({:cancel, schedule, _}, core),
    do: API.call(core, :cancel_schedule, [schedule.id, schedule.revision])

  defp run({:deliver, schedule, advanced, _, due, now}, core),
    do: API.call(core, :deliver_schedule, [schedule, due, advanced.next_at, now])

  defp complete_operation(state, {:register, schedule, options, now, from}, {:ok, stored}) do
    schedule = durable(schedule, stored)
    next = drop(state, schedule.id)
    reply(from, {:ok, public_schedule(schedule)})
    %{next | schedules: Map.put(next.schedules, schedule.id, arm(schedule, options, now))}
  end

  defp complete_operation(state, {:register, schedule, _, _, from}, error) do
    reply(from, operation_error(error))
    if unknown?(error), do: drop(state, schedule.id), else: state
  end

  defp complete_operation(state, {:cancel, schedule, from}, {:ok, stored}) do
    reply(from, {:ok, public_schedule(durable(schedule, stored))})
    drop(state, schedule.id)
  end

  defp complete_operation(state, {:cancel, schedule, from}, error) do
    reply(from, operation_error(error))
    if unknown?(error), do: drop(state, schedule.id), else: state
  end

  defp complete_operation(state, {:deliver, schedule, advanced, options, _, now}, {:ok, stored}) do
    advanced = durable(advanced, stored)
    %{state | schedules: Map.put(state.schedules, schedule.id, arm(advanced, options, now))}
  end

  defp complete_operation(state, {:deliver, schedule, _, options, due, _}, error) do
    cond do
      retryable?(error) or unknown?(error) ->
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
        cancelled_at: stored.cancelled_at,
        active_job_id: Map.get(stored, :active_job_id)
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

  defp reply({:admitted, guardian, engine, {slot, token}, from}, result),
    do: send(guardian, {:completed, engine, slot, token, from, result, %{}})

  defp reply(from, result), do: GenServer.reply(from, result)

  defp public_schedule(schedule), do: Tay.Schedule.public(schedule, :summary)

  defp atom_reason(reason, _) when is_atom(reason), do: Atom.to_string(reason)
  defp atom_reason(_, fallback), do: fallback
  defp unknown_reason(:submitted_request_lost), do: "caller_timeout_or_disconnect"
  defp unknown_reason({:generation_lost, _}), do: "generation_lost"
  defp unknown_reason(_), do: "outcome_unknown"
  defp identifier, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
end
