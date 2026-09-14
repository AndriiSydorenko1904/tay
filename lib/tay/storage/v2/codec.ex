defmodule Tay.Storage.V2.Codec do
  @moduledoc """
  Pure Store-v2 payload codec. Record-v1 framing supplies the type/schema,
  sequence and CRC; this module defines only the bounded semantic payloads.
  """

  alias Tay.Event
  alias Tay.Event.{V1, Value}

  @max 18_446_744_073_709_551_615
  @states ~w(scheduled available executing retryable completed cancelled discarded)
  @kinds %{inserted: 1, available: 2, started: 3, finished: 4, cancelled: 5, retried: 6}
  @snapshot_keys ~w(definition state attempt next_attempt eligible_at availability_order inserted_at attempted_at completed_at terminal_at diagnostic)
  @bodies %{
    inserted: ~w(definition eligible_at availability_order),
    available: ~w(due_at availability_order),
    started: ~w(attempt cycle_token),
    finished: ~w(outcome disposition execution_token next_attempt next_due_at diagnostic),
    cancelled: ~w(execution_token),
    retried: ~w(mode new_due_at availability_order)
  }

  def snapshot_type, do: 7
  def mutation_type, do: 8
  def schema, do: 1

  def encode_snapshot(job, limits \\ Value.defaults()) do
    with :ok <- snapshot?(job, limits),
         {:ok, body} <- Value.encode(snapshot_body(job), limits),
         execution <- Map.get(job, :execution),
         present <- if(is_nil(execution), do: <<0>>, else: <<1, execution::64>>),
         payload <-
           <<job.id::binary-size(16), job.revision::64, job.cycle::64, present::binary,
             body::binary>>,
         true <- byte_size(payload) <= 16_777_216 || {:error, :payload_too_large} do
      {:ok, payload}
    end
  end

  def decode_snapshot(payload, limits \\ Value.defaults())

  def decode_snapshot(payload, limits)
      when is_binary(payload) and byte_size(payload) <= 16_777_216 do
    with <<id::binary-size(16), revision::64, cycle::64, present, rest::binary>> <- payload,
         {:ok, execution, body_bytes} <- execution(present, rest),
         {:ok, body} <- Value.decode(body_bytes, limits),
         true <- exact?(body, @snapshot_keys) || {:error, :snapshot_keys},
         {:ok, job} <- snapshot_job(id, revision, cycle, execution, body, limits),
         :ok <- snapshot?(job, limits) do
      {:ok, job}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_snapshot}
    end
  end

  def decode_snapshot(payload, _) when is_binary(payload), do: {:error, :payload_too_large}
  def decode_snapshot(_, _), do: {:error, :invalid_snapshot}

  def encode_mutation(mutation, limits \\ Value.defaults()) do
    with :ok <- mutation?(mutation, limits),
         {:ok, body} <- Value.encode(mutation.body, limits),
         kind <- Map.fetch!(@kinds, mutation.kind),
         payload <-
           <<mutation.job_id::binary-size(16), kind, mutation.expected_revision::64,
             mutation.new_revision::64, mutation.at::64, body::binary>>,
         true <- byte_size(payload) <= 16_777_216 || {:error, :payload_too_large} do
      {:ok, payload}
    end
  end

  def decode_mutation(payload, limits \\ Value.defaults())

  def decode_mutation(payload, limits)
      when is_binary(payload) and byte_size(payload) <= 16_777_216 do
    with <<id::binary-size(16), kind_byte, expected::64, revision::64, at::64,
           body_bytes::binary>> <- payload,
         {:ok, kind} <- kind(kind_byte),
         {:ok, body} <- Value.decode(body_bytes, limits),
         mutation <- %{
           job_id: id,
           kind: kind,
           expected_revision: expected,
           new_revision: revision,
           at: at,
           body: body
         },
         :ok <- mutation?(mutation, limits) do
      {:ok, mutation}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_mutation}
    end
  end

  def decode_mutation(payload, _) when is_binary(payload), do: {:error, :payload_too_large}
  def decode_mutation(_, _), do: {:error, :invalid_mutation}

  def mutation?(mutation, limits \\ Value.defaults())

  def mutation?(
        %{
          job_id: id,
          kind: kind,
          expected_revision: expected,
          new_revision: revision,
          at: at,
          body: body
        },
        limits
      ) do
    with true <- V1.id?(id) || {:error, :job_id},
         true <- Map.has_key?(@kinds, kind) || {:error, :mutation_kind},
         true <- (is_integer(expected) and expected in 0..(@max - 1)) || {:error, :revision},
         true <- revision == expected + 1 || {:error, :revision},
         true <- kind == :inserted == (expected == 0) || {:error, :revision},
         true <- V1.time?(at) || {:error, :timestamp},
         true <- exact?(body, @bodies[kind]) || {:error, :mutation_keys},
         true <- mutation_order?(kind, at, body) || {:error, :availability_order},
         event <- event(kind, id, expected, at, body),
         {:ok, _} <- Event.encode(event, limits) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_mutation}
    end
  end

  def mutation?(_, _), do: {:error, :invalid_mutation}

  def event(%{kind: kind, job_id: id, expected_revision: expected, at: at, body: body}),
    do: event(kind, id, expected, at, body)

  defp event(kind, id, expected, at, body) do
    %Event{
      record_type: @kinds[kind],
      data:
        body
        |> Map.delete("availability_order")
        |> Map.merge(%{"job_id" => id, "expected_revision" => expected, "at" => at})
    }
  end

  defp snapshot_body(job) do
    %{
      "definition" => job.definition,
      "state" => Atom.to_string(job.state),
      "attempt" => job.attempt,
      "next_attempt" => job.next_attempt,
      "eligible_at" => job.eligible_at,
      "availability_order" => job.availability_order,
      "inserted_at" => job.inserted_at,
      "attempted_at" => job.attempted_at,
      "completed_at" => job.completed_at,
      "terminal_at" => job.terminal_at,
      "diagnostic" => job.diagnostic
    }
  end

  defp snapshot_job(id, revision, cycle, execution, body, limits) do
    case Enum.find(@states, &(&1 == body["state"])) do
      nil ->
        {:error, :snapshot_state}

      state ->
        definition = body["definition"]

        with {:ok, bytes} <- Value.encode(definition, limits) do
          {:ok,
           %{
             id: id,
             revision: revision,
             cycle: cycle,
             execution: execution,
             definition: definition,
             definition_bytes: bytes,
             state: String.to_existing_atom(state),
             attempt: body["attempt"],
             next_attempt: body["next_attempt"],
             eligible_at: body["eligible_at"],
             availability_order: body["availability_order"],
             inserted_at: body["inserted_at"],
             attempted_at: body["attempted_at"],
             completed_at: body["completed_at"],
             terminal_at: body["terminal_at"],
             diagnostic: body["diagnostic"]
           }}
        end
    end
  end

  def snapshot?(job, limits \\ Value.defaults())

  def snapshot?(job, limits) when is_map(job) do
    state = Map.get(job, :state)
    definition = Map.get(job, :definition)
    revision = Map.get(job, :revision)
    cycle = Map.get(job, :cycle)
    execution = Map.get(job, :execution)
    attempt = Map.get(job, :attempt)
    next_attempt = Map.get(job, :next_attempt)
    eligible = Map.get(job, :eligible_at)
    available = Map.get(job, :availability_order)
    inserted = Map.get(job, :inserted_at)
    attempted = Map.get(job, :attempted_at)
    completed = Map.get(job, :completed_at)
    terminal = Map.get(job, :terminal_at)
    diagnostic = Map.get(job, :diagnostic)

    with true <- V1.id?(Map.get(job, :id)) || {:error, :job_id},
         true <- V1.definition?(definition) || {:error, :definition},
         {:ok, definition_bytes} <- Value.encode(definition, limits),
         true <-
           Map.get(job, :definition_bytes) == definition_bytes || {:error, :definition_bytes},
         true <- (is_atom(state) and Atom.to_string(state) in @states) || {:error, :state},
         true <- (uint?(revision) and uint?(cycle) and cycle <= revision) || {:error, :revision},
         true <-
           (is_integer(attempt) and attempt in 0..definition["max_attempts"]) ||
             {:error, :attempt},
         true <-
           (is_nil(next_attempt) or
              (is_integer(next_attempt) and next_attempt in 1..definition["max_attempts"])) ||
             {:error, :next_attempt},
         true <-
           (V1.time?(inserted) and maybe_time?(eligible) and maybe_time?(attempted) and
              maybe_time?(completed) and maybe_time?(terminal)) || {:error, :timestamp},
         true <-
           (is_nil(available) or uint?(available)) || {:error, :availability_order},
         true <-
           (is_nil(execution) or (uint?(execution) and execution <= revision)) ||
             {:error, :execution_token},
         true <- valid_diagnostic?(diagnostic) || {:error, :diagnostic},
         true <- terminal_fields?(state, terminal, completed) || {:error, :terminal_at},
         true <-
           state_fields?(state, next_attempt, eligible, available, execution, completed) ||
             {:error, :state_fields},
         true <- credible_state?(state, job) || {:error, :state_fields} do
      :ok
    end
  end

  def snapshot?(_, _), do: {:error, :invalid_snapshot}

  defp state_fields?(:scheduled, n, at, nil, nil, nil), do: not is_nil(n) and not is_nil(at)

  defp state_fields?(:available, n, at, rev, nil, nil),
    do: not is_nil(n) and not is_nil(at) and not is_nil(rev)

  defp state_fields?(:retryable, n, at, nil, nil, nil), do: not is_nil(n) and not is_nil(at)
  defp state_fields?(:executing, n, nil, nil, token, nil), do: not is_nil(n) and not is_nil(token)
  defp state_fields?(:completed, nil, nil, nil, nil, at), do: not is_nil(at)

  defp state_fields?(state, nil, nil, nil, nil, nil) when state in [:cancelled, :discarded],
    do: true

  defp state_fields?(_, _, _, _, _, _), do: false

  defp terminal_fields?(:completed, at, completed),
    do: V1.time?(at) and at == completed

  defp terminal_fields?(state, at, nil) when state in [:cancelled, :discarded],
    do: V1.time?(at)

  defp terminal_fields?(state, at, _) when state not in [:completed, :cancelled, :discarded],
    do: is_nil(at)

  defp terminal_fields?(_, _, _), do: false

  defp credible_state?(:scheduled, job),
    do:
      job.revision == 1 and job.cycle == 1 and job.attempt == 0 and
        job.next_attempt == 1 and is_nil(job.attempted_at) and is_nil(job.diagnostic)

  defp credible_state?(:available, job),
    do:
      (job.attempt == 0 and job.next_attempt == 1 and is_nil(job.attempted_at)) or
        (job.attempt > 0 and not is_nil(job.attempted_at))

  defp credible_state?(:executing, job),
    do:
      job.attempt > 0 and not is_nil(job.attempted_at) and
        job.execution == job.revision and job.next_attempt == job.attempt

  defp credible_state?(:retryable, job),
    do: job.attempt > 0 and not is_nil(job.attempted_at) and not is_nil(job.diagnostic)

  defp credible_state?(:completed, job),
    do: job.attempt > 0 and not is_nil(job.attempted_at)

  defp credible_state?(:discarded, job),
    do: job.attempt > 0 and not is_nil(job.attempted_at) and not is_nil(job.diagnostic)

  defp credible_state?(:cancelled, _job), do: true

  defp mutation_order?(:inserted, at, %{
         "eligible_at" => eligible,
         "availability_order" => order
       }),
       do: if(is_integer(eligible) and eligible <= at, do: uint?(order), else: is_nil(order))

  defp mutation_order?(kind, _, %{"availability_order" => order})
       when kind in [:available, :retried],
       do: uint?(order)

  defp mutation_order?(_, _, _), do: true

  defp valid_diagnostic?(nil), do: true

  defp valid_diagnostic?(%{"version" => 1, "code" => code} = d),
    do: map_size(d) == 2 and code in 1..7

  defp valid_diagnostic?(_), do: false

  defp execution(0, rest), do: {:ok, nil, rest}
  defp execution(1, <<token::64, rest::binary>>) when token > 0, do: {:ok, token, rest}
  defp execution(_, _), do: {:error, :execution_token}

  defp kind(byte) do
    case Enum.find(@kinds, fn {_, n} -> n == byte end) do
      {kind, _} -> {:ok, kind}
      nil -> {:error, :mutation_kind}
    end
  end

  defp exact?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp uint?(n), do: is_integer(n) and n in 1..@max
  defp maybe_time?(nil), do: true
  defp maybe_time?(n), do: V1.time?(n)
end
