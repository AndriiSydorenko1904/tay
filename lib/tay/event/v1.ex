defmodule Tay.Event.V1 do
  @moduledoc false
  @common ~w(at expected_revision job_id)
  @fields %{
    1 => ~w(definition eligible_at),
    2 => ~w(due_at),
    3 => ~w(attempt cycle_token),
    4 => ~w(diagnostic disposition execution_token next_attempt next_due_at outcome),
    5 => ~w(execution_token),
    6 => ~w(mode new_due_at)
  }
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
  @max_time 9_223_372_036_854_775_807
  def policy, do: @policy
  def max_time, do: @max_time
  def time?(n), do: is_integer(n) and n in 0..@max_time
  def sequence?(n), do: is_integer(n) and n in 1..18_446_744_073_709_551_615
  def attempt?(n), do: is_integer(n) and n in 1..65_535
  def id?(id), do: is_binary(id) and byte_size(id) == 16 and id != <<0::128>>

  def key?(key),
    do:
      is_binary(key) and byte_size(key) in 1..255 and String.valid?(key) and
        not String.contains?(key, <<0>>)

  # Called only after bounded Value validation. This walk does not create atoms
  # or treat arbitrary map/tuple/struct values as serialized runtime terms.
  def definition?(d) do
    exact?(d, @definition) and is_map(d["args"]) and args?(d["args"]) and
      d["definition_version"] === 1 and attempt?(d["max_attempts"]) and
      key?(d["worker_key"]) and key?(d["queue_key"]) and d["retry_policy"] === @policy and
      (d["scheduled_at"] == nil or time?(d["scheduled_at"])) and
      is_integer(d["timeout_ms"]) and d["timeout_ms"] in 1..86_400_000
  end

  def validate(type, data) do
    if Map.has_key?(@fields, type) and exact?(data, @common ++ @fields[type]) and
         time?(data["at"]) and id?(data["job_id"]) and
         revision?(type, data["expected_revision"]) and fields?(type, data),
       do: :ok,
       else: {:error, :invalid_event}
  end

  defp exact?(data, keys),
    do: is_map(data) and not is_struct(data) and Enum.sort(Map.keys(data)) == Enum.sort(keys)

  defp revision?(1, n), do: n === 0
  defp revision?(_, n), do: sequence?(n)

  defp fields?(1, d),
    do:
      definition?(d["definition"]) and time?(d["eligible_at"]) and
        d["eligible_at"] === (d["definition"]["scheduled_at"] || d["at"])

  defp fields?(2, d), do: time?(d["due_at"]) and d["due_at"] <= d["at"]
  defp fields?(3, d), do: attempt?(d["attempt"]) and sequence?(d["cycle_token"])

  defp fields?(4, d) do
    sequence?(d["execution_token"]) and finish?(d["outcome"], d["disposition"], d["diagnostic"]) and
      if(d["disposition"] === 1,
        do: attempt?(d["next_attempt"]) and time?(d["next_due_at"]),
        else: d["next_attempt"] == nil and d["next_due_at"] == nil
      )
  end

  defp fields?(5, d), do: d["execution_token"] == nil or sequence?(d["execution_token"])

  defp fields?(6, d),
    do:
      d["mode"] in [0, 1] and is_integer(d["mode"]) and time?(d["new_due_at"]) and
        d["new_due_at"] === d["at"]

  defp finish?(0, 0, nil), do: true

  defp finish?(1, disposition, %{"code" => code, "version" => 1} = d)
       when disposition in [1, 2] and code in [1, 2, 3, 4, 6],
       do: map_size(d) == 2 and is_integer(disposition) and is_integer(code)

  defp finish?(2, disposition, %{"code" => 5, "version" => 1} = d) when disposition in [1, 2],
    do: map_size(d) == 2 and is_integer(disposition)

  defp finish?(3, 1, %{"code" => 7, "version" => 1} = d), do: map_size(d) == 2
  defp finish?(_, _, _), do: false

  defp args?(x) when is_map(x) and not is_struct(x),
    do: Enum.all?(x, fn {k, v} -> is_binary(k) and args?(v) end)

  defp args?(x) when is_list(x), do: Enum.all?(x, &args?/1)
  defp args?(x), do: x in [nil, false, true] or is_number(x) or is_binary(x)

  @doc false
  def retry_delay(attempt) when is_integer(attempt) and attempt in 1..65_535 do
    # Branch before exponentiation: Event-v1 permits a large attempt ordinal,
    # but the fixed policy reaches its cap at the seventh execution.
    if attempt >= 7,
      do: @retry_cap_ms,
      else: @retry_base_ms * Integer.pow(2, attempt - 1)
  end

  def retry_jitter_max(delay) when is_integer(delay) and delay in 0..@retry_cap_ms,
    do: min(div(delay, @retry_jitter_divisor), @retry_cap_ms - delay)

  @doc false
  def retry_interval(at, attempt)
      when is_integer(at) and is_integer(attempt) and attempt in 1..65_535 do
    delay = retry_delay(attempt)
    jitter = retry_jitter_max(delay)
    {min(@max_time, at + delay), min(@max_time, at + delay + jitter)}
  end
end
