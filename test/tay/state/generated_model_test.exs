defmodule Tay.State.GeneratedModelTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Tay.State.{Transition, Projection}
  alias Tay.Event
  alias Tay.Event.Value
  alias Tay.Storage.Record
  alias Tay.Test.EventHelpers, as: E
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.NativeHelpers

  @fields ~w(id state attempt next_attempt cycle execution eligible_at available_sequence revision)a

  property "generated six-type model, indexes, wire replay and native full recovery agree after every step" do
    check all(choices <- list_of(integer(0..100), min_length: 20, max_length: 100), max_runs: 40) do
      Process.flag(:trap_exit, true)
      projection = Projection.new(%{"w" => __MODULE__}, %{"q" => :q})

      {candidate, models, frames, _} =
        Enum.reduce(choices, {Transition.candidate(), %{}, [], nil}, fn choice,
                                                                        {candidate, models,
                                                                         frames, current} ->
          seq = length(frames) + 1
          previous_model = if current, do: Map.get(models, current)
          {event, model} = produce(previous_model, choice, seq)
          previous = Map.get(candidate.jobs, model.id)
          {:ok, prepared} = Transition.prepare(previous, event)
          {:ok, live} = Transition.apply(prepared, %{sequence: seq})
          assert Map.take(live, @fields) == model

          assert {:error, _} =
                   Transition.prepare(previous, %{
                     event
                     | data: Map.put(event.data, "expected_revision", seq)
                   })

          :ok = Projection.replace(projection, previous, live)
          models = Map.put(models, model.id, model)
          # Independent oracle: no Projection/key/eligibility helper is reused.
          queue =
            for {id, %{state: :available} = m} <- models,
                do: {{"q", m.eligible_at, m.available_sequence, id}, id}

          schedule =
            for {id, m} <- models,
                m.state in [:scheduled, :retryable],
                do: {{m.eligible_at, id}, m.revision}

          assert Enum.sort(:ets.tab2list(projection.queue)) == Enum.sort(queue)
          assert Enum.sort(:ets.tab2list(projection.schedule)) == Enum.sort(schedule)
          assert :ets.info(projection.jobs, :size) == map_size(models)
          {:ok, {type, 1, payload}} = Event.encode(event)

          {:ok, frame} =
            Record.encode(%Record{
              record_type: type,
              payload_schema_version: 1,
              payload: payload,
              sequence: seq
            })

          {:ok, physical, <<>>} = Record.decode(frame)
          {:ok, decoded, _} = Event.decode_payload(type, 1, physical.payload, Value.defaults())
          {:ok, candidate} = Transition.reduce(decoded, %{sequence: seq}, candidate)
          assert Map.delete(candidate.jobs[model.id], :charge) == Map.delete(live, :charge)
          {candidate, models, [frame | frames], model.id}
        end)

      assert Enum.all?(candidate.jobs, fn {id, job} -> Map.take(job, @fields) == models[id] end)
      path = NativeHelpers.path()
      R.store(path, [R.segment(1, 1, Enum.reverse(frames))])

      try do
        spec = %{
          codec: Event,
          initial_acc: Transition.candidate(),
          reducer: &Transition.reduce/3,
          options: []
        }

        {:ok, writer} = R.start(path, spec)
        assert {:ok, _, ^candidate} = R.activate(writer)
        GenServer.stop(writer)
      after
        File.rm_rf!(path)

        for table <- [projection.jobs, projection.queue, projection.schedule],
            do: :ets.delete(table)
      end
    end
  end

  defp produce(nil, choice, seq) do
    due = if rem(choice, 2) == 0, do: nil, else: 10
    id = E.id(seq)
    event = E.inserted(E.definition(%{"scheduled_at" => due, "max_attempts" => 3}), 0, id)

    {event,
     %{
       id: id,
       state: if(due, do: :scheduled, else: :available),
       attempt: 0,
       next_attempt: 1,
       cycle: seq,
       execution: nil,
       eligible_at: due || 0,
       available_sequence: if(due, do: nil, else: seq),
       revision: seq
     }}
  end

  defp produce(%{state: state}, choice, seq) when state in [:completed, :cancelled],
    do: produce(nil, choice, seq)

  defp produce(%{state: :discarded} = p, _, seq) do
    e = E.event(6, 0, p.revision, %{"mode" => 1, "new_due_at" => 0}, p.id)

    {e,
     %{
       p
       | state: :available,
         attempt: 0,
         next_attempt: 1,
         cycle: seq,
         eligible_at: 0,
         available_sequence: seq,
         revision: seq
     }}
  end

  defp produce(%{state: state} = p, choice, seq) when state in [:scheduled, :retryable] do
    if state == :retryable and rem(choice, 2) == 0 do
      e = E.event(6, 0, p.revision, %{"mode" => 0, "new_due_at" => 0}, p.id)
      {e, %{p | state: :available, eligible_at: 0, available_sequence: seq, revision: seq}}
    else
      e = E.event(2, p.eligible_at, p.revision, %{"due_at" => p.eligible_at}, p.id)
      {e, %{p | state: :available, available_sequence: seq, revision: seq}}
    end
  end

  defp produce(%{state: :available} = p, choice, seq) do
    if rem(choice, 5) == 0 do
      cancel(p, seq)
    else
      e =
        E.event(
          3,
          p.eligible_at,
          p.revision,
          %{"attempt" => p.next_attempt, "cycle_token" => p.cycle},
          p.id
        )

      {e,
       %{
         p
         | state: :executing,
           attempt: p.next_attempt,
           execution: seq,
           eligible_at: nil,
           available_sequence: nil,
           revision: seq
       }}
    end
  end

  defp produce(%{state: :executing} = p, choice, seq) do
    case rem(choice, 5) do
      4 ->
        cancel(p, seq)

      n ->
        {outcome, code} = Enum.at([{0, nil}, {2, 5}, {3, 7}, {1, 1}], n)

        {disposition, next, state} =
          cond do
            outcome == 0 -> {0, nil, :completed}
            outcome == 3 -> {1, p.attempt, :retryable}
            p.attempt < 3 -> {1, p.attempt + 1, :retryable}
            true -> {2, nil, :discarded}
          end

        due = if next, do: min(60_000, 1000 * Integer.pow(2, p.attempt - 1)), else: nil

        e =
          E.event(
            4,
            0,
            p.revision,
            %{
              "outcome" => outcome,
              "disposition" => disposition,
              "execution_token" => p.execution,
              "diagnostic" => if(code, do: %{"code" => code, "version" => 1}, else: nil),
              "next_attempt" => next,
              "next_due_at" => due
            },
            p.id
          )

        {e,
         %{p | state: state, next_attempt: next, execution: nil, eligible_at: due, revision: seq}}
    end
  end

  defp cancel(p, seq) do
    {E.event(5, 0, p.revision, %{"execution_token" => p.execution}, p.id),
     %{
       p
       | state: :cancelled,
         next_attempt: nil,
         execution: nil,
         eligible_at: nil,
         available_sequence: nil,
         revision: seq
     }}
  end
end
