defmodule Tay.Storage.Writer.SegmentOps do
  @moduledoc false

  alias Tay.Storage.{CRC32C, Native, Record, Segment}
  alias Tay.Storage.Writer.GroupCommit

  @test Mix.env() == :test
  @footer_bytes 64

  def encode_candidate(state, type, schema, payload) do
    if state.next_sequence > Segment.max_id() do
      {:error, :sequence_exhausted}
    else
      Record.encode(%Record{
        sequence: state.next_sequence,
        record_type: type,
        payload_schema_version: schema,
        payload: payload
      })
    end
  end

  def append_with_capacity(state, bytes) do
    rotate? =
      state.segment.state == :sealed or
        state.segment.bytes + byte_size(bytes) + @footer_bytes >
          state.options.rotation_target_bytes

    if rotate? do
      with {:ok, next} <- rotate(state),
           do: append_bytes(next, bytes)
    else
      append_bytes(state, bytes)
    end
  end

  def rotate(%{segment: %{state: :active, count: 0}} = state), do: {:ok, state}

  def rotate(state) do
    cond do
      state.segment.id == Segment.max_id() ->
        {:reject, :segment_id_exhausted}

      state.next_sequence > Segment.max_id() ->
        {:reject, :sequence_exhausted}

      state.segment.state == :sealed ->
        create_successor(state)

      true ->
        with {:ok, sealed} <- seal(state), do: create_successor(sealed)
    end
  end

  def create_successor(state) do
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
         {:ok, staged_identity} <-
           step(state, {:r3, :created}, fn -> Native.create_stage(native, :segments, source) end),
         {:ok, %{identity: identity}} <-
           step(state, :r3, fn -> Native.write(native, 0, bytes) end),
         :ok <- step(state, {:r4, :synced}, fn -> Native.sync(native) end),
         :ok <- step(state, :r4, fn -> Native.close_write(native) end),
         :ok <-
           step(state, :r5, fn ->
             Native.publish(native, :segments, source, canonical(id), staged_identity)
           end),
         :ok <- Native.sync_dir(native, :segments),
         {:ok, successor} <- successor(bytes, identity, id, state.next_sequence, state.store_id),
         :ok <- step(state, :r6, fn -> Native.check(native) end),
         {:ok, _} <-
           step(state, :r7, fn ->
             Native.open_active(native, canonical(id), successor.identity)
           end),
         :ok <- Native.check(native) do
      {:ok, %{state | segment: successor}}
    end
  end

  def open_ready(state, store) do
    state = %{
      state
      | segment: store.highest,
        store_id: store.store_id,
        next_sequence: store.next_sequence
    }

    with :ok <- sync_v2_authority(state),
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

  def sync_existing(state, scope, name) do
    with {:ok, _} <- Native.open_read(state.native, scope, name) do
      result = Native.sync_read(state.native)
      close = Native.close_read(state.native)
      if result == :ok, do: close, else: result
    end
  end

  def sync_v2_authority(state) do
    with :ok <- sync_existing(state, :root, "STORE-V2"),
         :ok <- sync_existing(state, :root, "CURRENT"),
         :ok <- sync_existing(state, :epoch, "MANIFEST"),
         :ok <- Native.sync_dir(state.native, :epoch),
         :ok <- Native.sync_dir(state.native, :epochs),
         do: :ok
  end

  def seal(state) do
    # Native.check is O(1). Full semantic replay belongs to startup recovery.
    with :ok <- step(state, :r0, fn -> Native.check(state.native) end) do
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
                 bytes: state.segment.bytes + @footer_bytes,
                 identity: identity
             }
         }}
      end
    end
  end

  defp successor(bytes, identity, id, first_sequence, store_id) do
    with {:ok, segment} <- Segment.decode_header(bytes, %{id: id, store_id: store_id}),
         true <- segment.first_sequence == first_sequence || {:error, :successor_mismatch},
         true <- identity.size == byte_size(bytes) || {:error, :successor_mismatch} do
      {:ok,
       %{
         segment
         | state: :active,
           identity: identity,
           crc_state: CRC32C.update(CRC32C.initial(), bytes)
       }}
    end
  end

  defp append_bytes(state, bytes) do
    offset = state.segment.bytes

    with {:ok, %{identity: identity}} <-
           step(state, :append_written, fn -> Native.write(state.native, offset, bytes) end),
         :ok <- sync_append(state),
         :ok <- check_append(state) do
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

      next = %{state | segment: segment, next_sequence: state.next_sequence + 1}

      next =
        case Map.get(next, :group_commit) do
          nil -> next
          group -> Map.put(next, :group_commit, GroupCommit.increment(group))
        end

      {:ok, next, receipt}
    end
  end

  defp sync_append(%{options: %{durability: :write}}), do: :ok
  defp sync_append(state) when is_map_key(state, :group_commit), do: :ok
  defp sync_append(state), do: step(state, :append_synced, fn -> Native.sync(state.native) end)

  defp check_append(state) when is_map_key(state, :group_commit), do: :ok
  defp check_append(state), do: Native.check(state.native)

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

    defp hook(%{options: %{on_transition: fun}, native: native}, tag) when is_function(fun, 2),
      do: fun.(tag, native)

    defp hook(_, _), do: :ok
  else
    defp step(_state, _tag, operation), do: operation.()
  end

  defp stage_name(id),
    do:
      ".tay-new-" <> String.replace_suffix(canonical(id), ".tay", "") <> "-" <> nonce() <> ".tmp"

  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp canonical(id), do: elem(Segment.filename(id), 1)
end
