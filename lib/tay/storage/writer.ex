defmodule Tay.Storage.Writer do
  @moduledoc """
  Internal physical storage session with a supervised native Port.

  The GenServer serializes storage operations and supervises its linked helper.
  The helper alone holds flock and writable FDs. A failed or uncertain mutation
  poisons this instance; no automatic restart/retry is permitted. An embedding
  supervisor may start this temporary child explicitly. Physical readiness is
  not Event validation, job insertion, or semantic recovery readiness.
  """
  use GenServer, restart: :temporary
  alias Tay.Storage.{CRC32C, Native, Reader, Record, Segment}
  @test Mix.env() == :test

  def start_link(options) do
    if Keyword.keyword?(options),
      do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name])),
      else: {:error, :invalid_writer_options}
  end

  def status(writer), do: GenServer.call(writer, :status, :infinity)
  @doc "Appends opaque physical bytes supplied by an upstream semantic validator."
  def append(writer, type, schema, payload),
    do: GenServer.call(writer, {:append, type, schema, payload}, :infinity)

  def reduce(writer, accumulator, reducer),
    do: GenServer.call(writer, {:reduce, accumulator, reducer}, :infinity)

  def seal(writer), do: GenServer.call(writer, :seal, :infinity)
  def rotate(writer), do: GenServer.call(writer, :rotate, :infinity)

  if @test do
    def inject_fault(writer, operation, occurrence, action, errno \\ 5, count \\ 0),
      do: GenServer.call(writer, {:fault, operation, occurrence, action, errno, count}, :infinity)
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    with {:ok, options} <- options(options),
         {:ok, native} <- Native.open(options.data_dir, Map.to_list(options)) do
      state = %{
        native: native,
        options: options,
        segment: nil,
        store_id: nil,
        next_sequence: 1,
        poisoned: nil
      }

      case prepare(state) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          Native.shutdown(native)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(_request, _from, %{poisoned: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, {:poisoned, reason}}, state}

  def handle_call({:append, type, schema, payload}, _from, state) do
    case encode_candidate(state, type, schema, payload) do
      {:ok, bytes} ->
        case append_with_capacity(state, bytes, type, schema, payload) do
          {:ok, next, receipt} -> {:reply, {:ok, receipt}, next}
          {:reject, reason} -> {:reply, {:error, reason}, state}
          {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:reduce, accumulator, reducer}, _from, state) do
    case Reader.reduce(state.native, accumulator, reducer) do
      {:ok, _} = result -> {:reply, result, state}
      {:error, reason} = result -> {:reply, result, poison(state, reason)}
    end
  end

  def handle_call(:seal, _from, state) do
    cond do
      state.segment.state == :sealed ->
        {:reply, {:error, :already_sealed}, state}

      state.segment.count == 0 ->
        {:reply, {:error, :empty_segment}, state}

      true ->
        case seal_segment(state) do
          {:ok, next} -> {:reply, {:ok, next.segment}, next}
          {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
        end
    end
  end

  def handle_call(:rotate, _from, state) do
    case rotate_segment(state) do
      {:ok, next} -> {:reply, {:ok, next.segment}, next}
      {:reject, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, {:uncertain, reason}}, poison(state, reason)}
    end
  end

  if @test do
    def handle_call({:fault, operation, occurrence, action, errno, count}, _from, state) do
      result = Native.fault(state.native, operation, occurrence, action, errno, count)
      {:reply, result, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, {:helper_exit, code})}

  def handle_info({:EXIT, port, reason}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, {:port_exit, reason})}

  def handle_info({port, {:data, _}}, %{native: %{port: port}} = state),
    do: {:noreply, poison(state, :unsolicited_native_reply)}

  @impl true
  def terminate(_reason, state), do: Native.shutdown(state.native)

  defp options(options) do
    allowed =
      [
        :name,
        :data_dir,
        :durability,
        :validated_filesystem,
        :rotation_target_bytes,
        :bootstrap,
        :timeout
      ] ++ if(@test, do: [:test_helper, :on_transition], else: [])

    with true <- Keyword.keyword?(options) || {:error, :invalid_writer_options},
         true <-
           length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) ||
             {:error, :duplicate_writer_options},
         true <-
           Enum.all?(Keyword.keys(options), &(&1 in allowed)) || {:error, :unknown_writer_option},
         {:ok, config} <- Tay.Config.new(data_dir: Keyword.get(options, :data_dir)),
         true <- config.data_dir != nil || {:error, :data_dir_required} do
      opts =
        Enum.into(options, %{
          data_dir: config.data_dir,
          durability: :sync,
          validated_filesystem: false,
          rotation_target_bytes: 67_108_864,
          bootstrap: false,
          timeout: 10_000,
          test_helper: false,
          on_transition: nil
        })
        |> Map.put(:data_dir, config.data_dir)

      cond do
        opts.durability not in [:write, :sync] ->
          {:error, :invalid_durability}

        not is_boolean(opts.validated_filesystem) ->
          {:error, :invalid_filesystem_validation}

        not is_boolean(opts.bootstrap) ->
          {:error, :invalid_bootstrap_intent}

        not is_integer(opts.timeout) or opts.timeout <= 0 ->
          {:error, :invalid_timeout}

        not is_integer(opts.rotation_target_bytes) or
          opts.rotation_target_bytes < Segment.min_rotation_bytes() or
            opts.rotation_target_bytes > Segment.max_bytes() ->
          {:error, :invalid_rotation_target}

        true ->
          {:ok, opts}
      end
    end
  end

  defp prepare(state) do
    with {:ok, store} <- Reader.inspect_store(state.native) do
      case store.state do
        :uninitialized -> bootstrap(state, store)
        :genesis -> complete_genesis(%{state | store_id: store.store_id})
        :ready -> open_ready(state, store)
      end
    end
  end

  defp encode_candidate(state, type, schema, payload) do
    if state.next_sequence > Segment.max_id() do
      {:error, :sequence_exhausted}
    else
      record = %Record{
        sequence: state.next_sequence,
        record_type: type,
        payload_schema_version: schema,
        payload: payload
      }

      Record.encode(record)
    end
  end

  defp append_with_capacity(state, bytes, type, schema, payload) do
    rotate =
      state.segment.state == :sealed or
        state.segment.bytes + byte_size(bytes) + 64 > state.options.rotation_target_bytes

    if rotate do
      with {:ok, next} <- rotate_segment(state),
           # Recompute the final frame only after the successor is published.
           {:ok, final} <- encode_candidate(next, type, schema, payload),
           do: append_bytes(next, final)
    else
      append_bytes(state, bytes)
    end
  end

  defp rotate_segment(%{segment: %{state: :active, count: 0}} = state), do: {:ok, state}

  defp rotate_segment(state) do
    cond do
      state.segment.id == Segment.max_id() ->
        {:reject, :segment_id_exhausted}

      state.next_sequence > Segment.max_id() ->
        {:reject, :sequence_exhausted}

      state.segment.state == :sealed ->
        create_successor(state)

      true ->
        with {:ok, sealed} <- seal_segment(state), do: create_successor(sealed)
    end
  end

  defp create_successor(state) do
    id = state.segment.id + 1
    source = stage_name(id)
    native = state.native

    with :ok <- sync_existing(state, :segments, canonical(state.segment.id)),
         {:ok, bytes} <-
           Segment.encode_header(%{
             id: id,
             first_sequence: state.next_sequence,
             store_id: state.store_id
           }),
         {:ok, identity} <-
           step(state, {:r3, :created}, fn -> Native.create_stage(native, :segments, source) end),
         {:ok, _} <- step(state, :r3, fn -> Native.write(native, 0, bytes) end),
         :ok <- step(state, {:r4, :synced}, fn -> Native.sync(native) end),
         :ok <- step(state, :r4, fn -> Native.close_write(native) end),
         :ok <-
           step(state, :r5, fn ->
             Native.publish(native, :segments, source, canonical(id), identity)
           end),
         :ok <- Native.sync_dir(native, :segments),
         {:ok, store} <- Reader.inspect_store(native),
         true <-
           (store.highest.id == id and store.highest.state == :active and
              store.highest.count == 0 and store.next_sequence == state.next_sequence) ||
             {:error, :successor_mismatch},
         :ok <- step(state, :r6, fn -> Native.check(native) end),
         {:ok, _} <-
           step(state, :r7, fn ->
             Native.open_active(native, canonical(id), store.highest.identity)
           end),
         :ok <- Native.check(native) do
      {:ok, %{state | segment: store.highest}}
    end
  end

  defp append_bytes(state, bytes) do
    offset = state.segment.bytes

    with {:ok, %{identity: identity}} <-
           step(state, :append_written, fn -> Native.write(state.native, offset, bytes) end),
         :ok <- sync_append(state),
         :ok <- Native.check(state.native) do
      segment = %{
        state.segment
        | last_sequence: state.next_sequence,
          count: state.segment.count + 1,
          bytes: offset + byte_size(bytes),
          identity: identity,
          crc_state: CRC32C.update(state.segment.crc_state, bytes)
      }

      receipt = %{
        segment_id: segment.id,
        offset: offset,
        sequence: state.next_sequence,
        durability: state.options.durability
      }

      {:ok, %{state | segment: segment, next_sequence: state.next_sequence + 1}, receipt}
    end
  end

  defp sync_append(%{options: %{durability: :write}}), do: :ok
  defp sync_append(state), do: step(state, :append_synced, fn -> Native.sync(state.native) end)

  defp verify_current(state) do
    with {:ok, store} <- Reader.inspect_store(state.native) do
      fields = [
        :id,
        :first_sequence,
        :store_id,
        :state,
        :last_sequence,
        :count,
        :bytes,
        :crc_state
      ]

      if Map.take(store.highest, fields) == Map.take(state.segment, fields) and
           store.highest.identity.device == state.segment.identity.device and
           store.highest.identity.inode == state.segment.identity.inode do
        {:ok, %{state | segment: store.highest}}
      else
        {:error, :writer_state_mismatch}
      end
    end
  end

  defp seal_segment(state) do
    with {:ok, state} <- step(state, :r0, fn -> verify_current(state) end) do
      footer = %{
        id: state.segment.id,
        first_sequence: state.segment.first_sequence,
        last_sequence: state.segment.last_sequence,
        count: state.segment.count,
        store_id: state.store_id,
        segment_crc: CRC32C.finalize(state.segment.crc_state)
      }

      with {:ok, bytes} <- Segment.encode_footer(footer),
           {:ok, %{identity: identity}} <-
             step(state, :r1, fn -> Native.write(state.native, state.segment.bytes, bytes) end),
           :ok <- step(state, {:r2, :synced}, fn -> Native.sync(state.native) end),
           :ok <- step(state, :r2, fn -> Native.close_write(state.native) end),
           :ok <- Native.check(state.native) do
        {:ok,
         %{
           state
           | segment: %{
               state.segment
               | state: :sealed,
                 footer: footer,
                 bytes: state.segment.bytes + 64,
                 identity: identity
             }
         }}
      end
    end
  end

  defp bootstrap(state, store) do
    if state.native.facts.created or state.options.bootstrap do
      state = %{state | store_id: new_store_id()}

      with :ok <- ensure_segments(state, store.segments_directory),
           {:ok, header} <-
             Segment.encode_header(%{id: 1, first_sequence: 1, store_id: state.store_id}),
           :ok <-
             publish_file(
               state,
               :segments,
               stage_name(1),
               canonical(1),
               header,
               :bootstrap_header
             ) do
        complete_genesis(state)
      end
    else
      {:error, :explicit_bootstrap_required}
    end
  end

  defp ensure_segments(_state, true), do: :ok

  defp ensure_segments(state, false) do
    with :ok <- step(state, {:bootstrap, :mkdir}, fn -> Native.mkdir_segments(state.native) end),
         :ok <-
           step(state, {:bootstrap, :sync_root}, fn -> Native.sync_dir(state.native, :root) end),
         do: :ok
  end

  defp complete_genesis(state) do
    with {:ok, marker} <- Segment.encode_store(state.store_id),
         :ok <- sync_existing(state, :segments, canonical(1)),
         :ok <- Native.sync_dir(state.native, :segments),
         :ok <-
           publish_file(
             state,
             :root,
             ".tay-store-" <> nonce() <> ".tmp",
             "STORE",
             marker,
             :bootstrap_store
           ),
         {:ok, store} <- Reader.inspect_store(state.native) do
      open_ready(state, store)
    end
  end

  defp open_ready(state, store) do
    state = %{
      state
      | segment: store.highest,
        store_id: store.store_id,
        next_sequence: store.next_sequence
    }

    with :ok <- sync_existing(state, :root, "STORE"),
         :ok <- Native.sync_dir(state.native, :root),
         :ok <- Native.sync_dir(state.native, :segments) do
      case store.highest.state do
        :active ->
          with :ok <- sync_existing(state, :segments, canonical(store.highest.id)),
               {:ok, _} <-
                 step(state, :open_active, fn ->
                   Native.open_active(
                     state.native,
                     canonical(store.highest.id),
                     store.highest.identity
                   )
                 end),
               :ok <- Native.check(state.native) do
            {:ok, state}
          end

        :sealed ->
          if store.exhausted, do: {:ok, state}, else: create_successor(state)
      end
    end
  end

  defp publish_file(state, scope, source, target, bytes, context) do
    with {:ok, identity} <-
           step(state, {context, :create}, fn ->
             Native.create_stage(state.native, scope, source)
           end),
         {:ok, _} <-
           step(state, {context, :write}, fn -> Native.write(state.native, 0, bytes) end),
         :ok <- step(state, {context, :sync}, fn -> Native.sync(state.native) end),
         :ok <- step(state, {context, :close}, fn -> Native.close_write(state.native) end),
         :ok <-
           step(state, {context, :publish}, fn ->
             Native.publish(state.native, scope, source, target, identity)
           end),
         :ok <- step(state, {context, :sync_dir}, fn -> Native.sync_dir(state.native, scope) end),
         :ok <- Native.check(state.native),
         do: :ok
  end

  defp sync_existing(state, scope, name) do
    with {:ok, _} <- Native.open_read(state.native, scope, name) do
      result = Native.sync_read(state.native)
      close = Native.close_read(state.native)
      if result == :ok, do: close, else: result
    end
  end

  if @test do
    defp step(state, tag, operation) do
      case operation.() do
        {:error, _} = error ->
          error

        result ->
          case hook(state, tag) do
            :ok -> result
            error -> error
          end
      end
    end
  else
    defp step(_state, _tag, operation), do: operation.()
  end

  if @test do
    defp hook(%{options: %{on_transition: fun}, native: native}, tag) when is_function(fun, 2),
      do: fun.(tag, native)
  end

  defp hook(_, _), do: :ok

  defp new_store_id do
    case :crypto.strong_rand_bytes(16) do
      <<0::128>> -> new_store_id()
      id -> id
    end
  end

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp canonical(id), do: elem(Segment.filename(id), 1)

  defp stage_name(id),
    do:
      ".tay-new-" <> String.replace_suffix(canonical(id), ".tay", "") <> "-" <> nonce() <> ".tmp"

  defp public_status(state),
    do: %{
      state: if(state.poisoned, do: :poisoned, else: :ready),
      reason: state.poisoned,
      segment: state.segment,
      next_sequence: state.next_sequence,
      durability: state.options.durability,
      os_pid: state.native.facts.os_pid
    }

  defp poison(%{poisoned: nil} = state, reason) do
    Native.shutdown(state.native)
    _ = hook(state, {:poisoned, reason})
    %{state | poisoned: reason}
  end

  defp poison(state, _), do: state
end
