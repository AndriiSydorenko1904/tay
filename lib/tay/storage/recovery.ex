defmodule Tay.Storage.Recovery do
  @moduledoc """
  Non-destructive recovery of existing initialized v1 stores.

  Full physical validation precedes semantic replay and pure private reduction.
  Complete understood events are replayed irrespective of previous caller ACKs.
  No parse result authorizes repair, skipping, sequence reuse or writable access.
  The recovered Writer retains ownership and separately activates the candidate.
  """
  alias Tay.Storage.{Native, Reader}
  alias __MODULE__.Error

  @defaults %{
    max_decode_payload_bytes: 16_777_216,
    max_directory_entries: 100_000,
    max_total_segment_bytes: :infinity,
    max_replay_records: :infinity,
    deadline_ms: 900_000,
    activation_window_ms: 30_000,
    activation_deadline_ms: 900_000,
    io_timeout_ms: 10_000,
    event_limits: %{depth: 64, output_nodes: 100_000, binary_bytes: 16_777_216}
  }

  @spec inspect(Native.t() | struct(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def inspect(native, options \\ []) do
    with {:ok, opts} <- options(options),
         :ok <- inspection_session(native),
         {:ok, view} <- Reader.preflight(bounded_native(native, opts), Map.to_list(opts)) do
      {:ok, summary(view)}
    else
      {:error, reason} -> {:error, Error.wrap(reason, :preflight)}
    end
  end

  @spec replay(struct(), module(), term(), function(), keyword()) ::
          {:ok, map(), term()} | {:error, Error.t()}
  def replay(native, codec, initial_acc, reducer, options \\ []) do
    case prepare(native, codec, initial_acc, reducer, options) do
      {:ok, result, candidate, _view, _identity} -> {:ok, result, candidate}
      error -> error
    end
  end

  @doc false
  def prepare(native, codec, initial_acc, reducer, options) do
    with {:ok, opts} <- options(options),
         {:ok, identity} <- provider(codec, reducer),
         :ok <- inspection_session(native) do
      native = bounded_native(native, opts)

      with {:ok, view} <- physical(native, opts),
           {:ok, {candidate, last_accepted, last_reduced}} <-
             Reader.reduce_while(
               native,
               view,
               {initial_acc, nil, nil},
               fn record, position, {acc, _accepted, _reduced} ->
                 with :ok <- provider_unchanged(identity),
                      {:ok, event} <- decode(codec, record, position, opts.event_limits),
                      :ok <- check_deadline(native),
                      accepted = position,
                      {:ok, next} <- consume(reducer, event, position, acc),
                      :ok <- check_deadline(native) do
                   {:cont, {next, accepted, position}}
                 end
               end,
               Map.to_list(opts)
             ),
           :ok <- provider_unchanged(identity) do
        result =
          Map.merge(summary(view), %{
            scope: :candidate,
            provider: identity,
            last_accepted: last_accepted,
            last_reduced: last_reduced
          })

        {:ok, result, candidate, view, identity}
      else
        {:error, reason} -> {:error, Error.wrap(reason, :replay)}
      end
    end
  end

  defp physical(native, opts) do
    case Reader.preflight(native, Map.to_list(opts)) do
      {:error, reason} -> {:error, Error.wrap(reason, :preflight)}
      result -> result
    end
  end

  @doc false
  def revalidate(native, view, identity, opts) do
    with {:ok, actual} <- Reader.preflight(native, Map.to_list(opts)),
         true <-
           actual == view || {:error, Error.new(:changed_view, :physical_view, :revalidation)},
         :ok <- provider_unchanged(identity),
         :ok <- activation_budget(view, opts),
         :ok <- Native.check(native),
         do: :ok
  end

  @doc false
  def activation_budget(view, opts) do
    successor = view.store.highest.state == :sealed and not view.store.exhausted
    extra = if successor, do: 1, else: 0
    total = Enum.reduce(view.store.segments, 0, &(&1.bytes + &2))
    # A stage and its canonical successor are the same rename-published inode.
    packet = Enum.reduce(view.segment_entries, 4, &(byte_size(&1.name) + 39 + &2))

    with :ok <-
           budget(
             total + 44 * extra,
             opts.max_total_segment_bytes,
             :max_total_segment_bytes,
             :revalidation
           ),
         :ok <-
           budget(
             length(view.segment_entries) + extra,
             opts.max_directory_entries,
             :max_directory_entries,
             :revalidation
           ),
         :ok <- budget(packet + 105 * extra, 16_785_436 - 23, :native_packet_bytes, :revalidation),
         do: :ok
  end

  @doc false
  def summary(view) do
    store = view.store
    count = Enum.reduce(store.segments, 0, &(&1.count + &2))

    Map.merge(Map.take(store, [:store_id, :segments, :highest, :exhausted]), %{
      scope: :physical,
      record_count: count,
      segment_count: length(store.segments),
      total_segment_bytes: Enum.reduce(store.segments, 0, &(&1.bytes + &2)),
      physical_last_sequence: if(count == 0, do: nil, else: store.next_sequence - 1),
      next_sequence: if(store.exhausted, do: :exhausted, else: store.next_sequence),
      arithmetic_next_sequence: store.next_sequence,
      staging_count: view.staging_count,
      ignored_count: view.ignored_count
    })
  end

  @doc false
  def options(options) do
    if Keyword.keyword?(options) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &Map.has_key?(@defaults, &1)) do
      opts = Map.merge(@defaults, Map.new(options))
      if Enum.all?(opts, &valid_option?/1), do: {:ok, opts}, else: invalid_options()
    else
      invalid_options()
    end
  end

  defp valid_option?({:max_decode_payload_bytes, n}), do: is_integer(n) and n in 0..16_777_216
  defp valid_option?({:max_directory_entries, n}), do: is_integer(n) and n in 1..4_294_967_295

  defp valid_option?({:max_total_segment_bytes, n}),
    do: n == :infinity or (is_integer(n) and n > 0)

  defp valid_option?({:max_replay_records, n}), do: n == :infinity or (is_integer(n) and n >= 0)

  defp valid_option?({:event_limits, limits}) do
    is_map(limits) and map_size(limits) == 3 and
      Enum.all?([:depth, :output_nodes], &(is_integer(limits[&1]) and limits[&1] > 0)) and
      is_integer(limits[:binary_bytes]) and limits.binary_bytes >= 0
  end

  defp valid_option?({_, n}), do: is_integer(n) and n > 0
  defp invalid_options, do: {:error, Error.new(:argument, :invalid_recovery_options, :validation)}

  @doc false
  def bounded_native(native, opts) do
    %{
      native
      | timeout: opts.io_timeout_ms,
        deadline: native.deadline || System.monotonic_time(:millisecond) + opts.deadline_ms
    }
  end

  @doc false
  def check_deadline(native) do
    if is_integer(native.deadline) and System.monotonic_time(:millisecond) >= native.deadline,
      do: {:error, Error.new(:resource_limit, :deadline, :replay)},
      else: :ok
  end

  @doc false
  def budget(actual, limit, key, stage) do
    if limit == :infinity or actual <= limit,
      do: :ok,
      else: {:error, Error.new(:resource_limit, {key, actual, limit}, stage)}
  end

  @doc false
  def provider(codec, reducer) do
    if is_atom(codec) and codec not in [nil, false, true] and is_function(reducer, 3) and
         Code.ensure_loaded?(codec) and
         Enum.all?(
           [known_type?: 1, supported_schema?: 2, decode_payload: 4],
           fn {fun, arity} -> function_exported?(codec, fun, arity) end
         ) do
      {:ok, {codec, codec.module_info(:md5)}}
    else
      {:error, Error.new(:argument, :explicit_event_decoder_required, :validation)}
    end
  end

  defp provider_unchanged({codec, md5}) do
    if codec.module_info(:md5) == md5,
      do: :ok,
      else: {:error, Error.new(:callback, :event_provider_changed, :replay)}
  catch
    _, _ -> {:error, Error.new(:callback, :event_provider_unavailable, :replay)}
  end

  defp inspection_session(%Native{} = native) do
    if Native.inspection?(native),
      do: :ok,
      else: {:error, Error.new(:ownership_unavailable, :inspection_session_required, :ownership)}
  end

  defp inspection_session(_),
    do: {:error, Error.new(:argument, :invalid_native_session, :validation)}

  defp decode(codec, record, position, limits) do
    with {:ok, known} <- callback(fn -> codec.known_type?(record.record_type) end, position),
         :ok <- capability(known, :unknown_event_type, position),
         {:ok, supported} <-
           callback(
             fn -> codec.supported_schema?(record.record_type, record.payload_schema_version) end,
             position
           ),
         :ok <- capability(supported, :unsupported_payload_schema, position),
         {:ok, decoded} <-
           callback(
             fn ->
               codec.decode_payload(
                 record.record_type,
                 record.payload_schema_version,
                 record.payload,
                 limits
               )
             end,
             position
           ) do
      case decoded do
        {:ok, event, consumed}
        when is_integer(consumed) and consumed == byte_size(record.payload) ->
          {:ok, event}

        {:ok, _, _} ->
          semantic_error(:invalid_payload, :payload_consumption, position)

        {:error, {:resource_limit, key}} when is_atom(key) ->
          semantic_error(:resource_limit, key, position)

        {:error, reason} ->
          semantic_error(:invalid_payload, Error.callback_reason(reason), position)

        _ ->
          semantic_error(:callback, :invalid_decoder_result, position)
      end
    end
  end

  defp consume(reducer, event, position, acc) do
    with {:ok, result} <- callback(fn -> reducer.(event, position, acc) end, position) do
      case result do
        {:ok, next} ->
          {:ok, next}

        {:error, {:resource_limit, key}} when is_atom(key) ->
          semantic_error(:resource_limit, key, position)

        {:error, reason} ->
          semantic_error(:consumer_rejected, Error.callback_reason(reason), position)

        _ ->
          semantic_error(:callback, :invalid_consumer_result, position)
      end
    end
  end

  defp capability(true, _, _), do: :ok

  defp capability(false, reason, position),
    do: semantic_error(:unsupported_semantics, reason, position)

  defp capability(_, _, position),
    do: semantic_error(:callback, :invalid_capability_result, position)

  defp callback(fun, position) do
    {:ok, fun.()}
  catch
    kind, _ -> semantic_error(:callback, {:callback_failed, kind}, position)
  end

  defp semantic_error(kind, reason, position),
    do:
      {:error,
       Error.new(kind, reason, :replay, Map.put(position, :offset, position.record_offset))}
end
