defmodule Tay.Event.V2 do
  @moduledoc false

  # Event v2 owns the complete production semantic surface. Types 1..6 retain
  # their frozen Event-v1 meanings byte-for-byte. V2-only types use payload
  # schema 2 so they cannot collide with Store-v2's schema-1 snapshot/mutation
  # records, which already occupy physical record types 7 and 8.
  # Names are used by the implementation and documentation. Numeric codes are
  # kept only as the stable, compact representation written to the record log.
  @types %{
    job_inserted: %{
      code: 1,
      schema: 1,
      identity: "job_id",
      encoding: :bytes,
      revision: :insert,
      fields: ~w(at definition eligible_at expected_revision job_id)
    },
    job_available: %{
      code: 2,
      schema: 1,
      identity: "job_id",
      encoding: :bytes,
      revision: :existing,
      fields: ~w(at due_at expected_revision job_id)
    },
    job_started: %{
      code: 3,
      schema: 1,
      identity: "job_id",
      encoding: :bytes,
      revision: :existing,
      fields: ~w(at attempt cycle_token expected_revision job_id)
    },
    job_finished: %{
      code: 4,
      schema: 1,
      identity: "job_id",
      encoding: :bytes,
      revision: :existing,
      fields:
        ~w(at diagnostic disposition execution_token expected_revision job_id next_attempt next_due_at outcome)
    },
    job_cancelled: %{
      code: 5,
      schema: 1,
      identity: "job_id",
      encoding: :bytes,
      revision: :existing,
      fields: ~w(at execution_token expected_revision job_id)
    },
    job_retried: %{
      code: 6,
      schema: 1,
      identity: "job_id",
      encoding: :bytes,
      revision: :existing,
      fields: ~w(at expected_revision job_id mode new_due_at)
    },
    schedule_registered: %{
      code: 7,
      schema: 2,
      identity: "schedule_id",
      encoding: :string,
      revision: :upsert,
      fields: ~w(at definition expected_revision next_at schedule_id)
    },
    schedule_advanced: %{
      code: 8,
      schema: 2,
      identity: "schedule_id",
      encoding: :string,
      revision: :existing,
      fields: ~w(at due_at expected_revision next_at schedule_id)
    },
    schedule_cancelled: %{
      code: 9,
      schema: 2,
      identity: "schedule_id",
      encoding: :string,
      revision: :existing,
      fields: ~w(at expected_revision schedule_id)
    },
    result_recorded: %{
      code: 10,
      schema: 2,
      identity: "job_id",
      encoding: :bytes,
      revision: :existing,
      fields: ~w(at expected_revision job_id result)
    }
  }
  @types_by_code Map.new(@types, fn {name, spec} -> {spec.code, Map.put(spec, :name, name)} end)

  @job_inserted @types.job_inserted.code
  @job_available @types.job_available.code
  @job_started @types.job_started.code
  @job_finished @types.job_finished.code
  @job_cancelled @types.job_cancelled.code
  @job_retried @types.job_retried.code
  @schedule_registered @types.schedule_registered.code
  @schedule_advanced @types.schedule_advanced.code
  @schedule_cancelled @types.schedule_cancelled.code
  @result_recorded @types.result_recorded.code
  @schedule_definition ~w(args catch_up expression kind options overlap task timezone)
  @definition ~w(args definition_version max_attempts queue_key retry_policy scheduled_at timeout_ms worker_key)
  @retry_base_ms 1_000
  @retry_cap_ms 60_000
  @retry_jitter_divisor 4
  @policy %{
    "base_ms" => @retry_base_ms,
    "cap_ms" => @retry_cap_ms,
    "jitter_divisor" => @retry_jitter_divisor,
    "version" => 1
  }
  # Fixed-width storage limits and the product's one-day timeout policy.
  @max_time 9_223_372_036_854_775_807
  @max_sequence 18_446_744_073_709_551_615
  @max_attempt 65_535
  @max_timeout_ms 24 * 60 * 60 * 1_000

  def policy, do: @policy
  def max_time, do: @max_time
  def time?(n), do: is_integer(n) and n in 0..@max_time
  def sequence?(n), do: is_integer(n) and n in 1..@max_sequence
  def attempt?(n), do: is_integer(n) and n in 1..@max_attempt
  def id?(id), do: is_binary(id) and byte_size(id) == 16 and id != <<0::128>>

  def key?(key),
    do:
      is_binary(key) and byte_size(key) in 1..255 and String.valid?(key) and
        not String.contains?(key, <<0>>)

  def legacy_type?(type), do: match?(%{schema: 1}, Map.get(@types_by_code, type))
  def v2_type?(type), do: match?(%{schema: 2}, Map.get(@types_by_code, type))

  def type_code(name) when is_atom(name) do
    case Map.get(@types, name) do
      %{code: code} -> code
      _ -> nil
    end
  end

  def type_code(_), do: nil

  def type_name(code) when is_integer(code) do
    case Map.get(@types_by_code, code) do
      %{name: name} -> name
      _ -> nil
    end
  end

  def type_name(_), do: nil

  # Called only after bounded Value validation. This walk does not create atoms
  # or treat arbitrary map/tuple/struct values as serialized runtime terms.
  def definition?(d) do
    exact?(d, @definition) and is_map(d["args"]) and args?(d["args"]) and
      d["definition_version"] === 1 and attempt?(d["max_attempts"]) and
      key?(d["worker_key"]) and key?(d["queue_key"]) and d["retry_policy"] === @policy and
      (d["scheduled_at"] == nil or time?(d["scheduled_at"])) and
      is_integer(d["timeout_ms"]) and d["timeout_ms"] in 1..@max_timeout_ms
  end

  def known_type?(type), do: Map.has_key?(@types_by_code, type)

  def supported_schema?(type, schema),
    do: match?(%{schema: ^schema}, Map.get(@types_by_code, type))

  def validate(type, schema, data) do
    case Map.get(@types_by_code, type) do
      %{schema: ^schema} = spec ->
        if exact?(data, spec.fields) and time?(data["at"]) and identity?(spec, data) and
             revision?(spec.revision, data["expected_revision"]) and fields?(type, data),
           do: :ok,
           else: {:error, :invalid_event}

      _ ->
        {:error, :invalid_event}
    end
  end

  def binary_identity_field(type) do
    case Map.get(@types_by_code, type) do
      %{encoding: :bytes, identity: field} -> field
      _ -> nil
    end
  end

  defp exact?(data, keys),
    do: is_map(data) and not is_struct(data) and Enum.sort(Map.keys(data)) == Enum.sort(keys)

  defp revision?(:insert, n), do: n === 0
  defp revision?(:upsert, n), do: n === 0 or sequence?(n)
  defp revision?(:existing, n), do: sequence?(n)

  defp identity?(%{encoding: :bytes, identity: field}, data), do: id?(data[field])
  defp identity?(%{encoding: :string, identity: field}, data), do: identifier?(data[field])

  defp fields?(@job_inserted, d),
    do:
      definition?(d["definition"]) and time?(d["eligible_at"]) and
        d["eligible_at"] === (d["definition"]["scheduled_at"] || d["at"])

  defp fields?(@job_available, d), do: time?(d["due_at"]) and d["due_at"] <= d["at"]

  defp fields?(@job_started, d),
    do: attempt?(d["attempt"]) and sequence?(d["cycle_token"])

  defp fields?(@job_finished, d) do
    sequence?(d["execution_token"]) and finish?(d["outcome"], d["disposition"], d["diagnostic"]) and
      if(d["disposition"] === 1,
        do: attempt?(d["next_attempt"]) and time?(d["next_due_at"]),
        else: d["next_attempt"] == nil and d["next_due_at"] == nil
      )
  end

  defp fields?(@job_cancelled, d),
    do: d["execution_token"] == nil or sequence?(d["execution_token"])

  defp fields?(@job_retried, d),
    do:
      d["mode"] in [0, 1] and is_integer(d["mode"]) and time?(d["new_due_at"]) and
        d["new_due_at"] === d["at"]

  defp fields?(@schedule_registered, d),
    do: schedule_definition?(d["definition"]) and time?(d["next_at"])

  defp fields?(@schedule_advanced, d),
    do:
      time?(d["due_at"]) and time?(d["next_at"]) and d["due_at"] <= d["at"] and
        d["next_at"] > d["due_at"]

  defp fields?(@schedule_cancelled, _d), do: true
  defp fields?(@result_recorded, d), do: args?(d["result"])

  defp schedule_definition?(definition) do
    exact?(definition, @schedule_definition) and key?(definition["task"]) and
      is_map(definition["args"]) and args?(definition["args"]) and
      definition["kind"] in ["cron", "every"] and
      schedule_expression?(definition["kind"], definition["expression"]) and
      (is_nil(definition["timezone"]) or identifier?(definition["timezone"])) and
      definition["overlap"] in ["allow", "skip", "queue"] and
      definition["catch_up"] in ["latest", "all"] and is_map(definition["options"]) and
      args?(definition["options"])
  end

  defp schedule_expression?("cron", value), do: identifier?(value)
  defp schedule_expression?("every", value), do: is_integer(value) and value > 0
  defp schedule_expression?(_, _), do: false

  defp identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp finish?(0, 0, nil), do: true

  defp finish?(1, disposition, %{"code" => code, "version" => 1} = d)
       when disposition in [1, 2] and code in [1, 2, 3, 4, 6],
       do: map_size(d) == 2 and is_integer(disposition) and is_integer(code)

  defp finish?(2, disposition, %{"code" => 5, "version" => 1} = d)
       when disposition in [1, 2],
       do: map_size(d) == 2 and is_integer(disposition)

  defp finish?(3, 1, %{"code" => 7, "version" => 1} = d), do: map_size(d) == 2
  defp finish?(_, _, _), do: false

  defp args?(x) when is_map(x) and not is_struct(x),
    do: Enum.all?(x, fn {k, v} -> is_binary(k) and args?(v) end)

  defp args?(x) when is_list(x), do: Enum.all?(x, &args?/1)
  defp args?(x), do: x in [nil, false, true] or is_number(x) or is_binary(x)

  @doc false
  def retry_delay(attempt) when is_integer(attempt) and attempt in 1..@max_attempt do
    if attempt >= 7,
      do: @retry_cap_ms,
      else: @retry_base_ms * Integer.pow(2, attempt - 1)
  end

  def retry_jitter_max(delay) when is_integer(delay) and delay in 0..@retry_cap_ms,
    do: min(div(delay, @retry_jitter_divisor), @retry_cap_ms - delay)

  @doc false
  def retry_interval(at, attempt)
      when is_integer(at) and is_integer(attempt) and attempt in 1..@max_attempt do
    delay = retry_delay(attempt)
    jitter = retry_jitter_max(delay)
    {min(@max_time, at + delay), min(@max_time, at + delay + jitter)}
  end
end
