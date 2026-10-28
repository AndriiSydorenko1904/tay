defmodule Tay.Storage.Native.Codec do
  @moduledoc """
  Pure filesystem Port protocol v1 encoding and decoding.
  Correlation errors remain distinct from native I/O errors; only the Port
  owner decides when to poison a connection. No retry or process state lives here.
  """
  @ops %{
    acquire: 1,
    list: 2,
    mkdir: 3,
    open_read: 4,
    read: 5,
    close_read: 6,
    create_stage: 7,
    open_active: 8,
    write: 9,
    sync: 10,
    close_write: 11,
    publish: 12,
    sync_dir: 13,
    check: 14,
    info: 15,
    sync_read: 16,
    shutdown: 17,
    acquire_existing: 18,
    enable_mutations: 19,
    cold_target_open: 20,
    cold_stage_create: 21,
    cold_open_write: 22,
    cold_sync_staging: 23,
    cold_publish: 24,
    cold_sync_catalog: 25,
    cold_check: 26,
    cold_source: 27,
    cold_list: 28,
    v2_select: 29,
    v2_begin: 30,
    v2_publish_epoch: 31,
    v2_publish_current: 33,
    v2_space: 34,
    v2_reclaim: 37,
    acquire_if_missing: 38,
    v2_abort: 39,
    fault: 240
  }

  @doc false
  def operations, do: @ops

  def opcode(operation), do: Map.fetch!(@ops, operation)
  def encode_request(operation, id, body), do: <<1, opcode(operation), id::64, body::binary>>

  def decode_reply(bytes, operation, id) do
    op = opcode(operation)

    case bytes do
      <<1, ^op, ^id::64, 0, 0::32, written::64, reply::binary>> ->
        {:ok, reply, written}

      <<1, ^op, ^id::64, 1, errno::32, written::64, reason::binary>> ->
        {:error,
         %{
           kind: :native_io,
           operation: operation,
           errno: errno,
           reason: reason,
           bytes_written: if(written == 18_446_744_073_709_551_615, do: :unknown, else: written)
         }}

      _ ->
        :invalid_reply
    end
  end

  def identity(
        <<size::64, device::64, inode::64, links::64, type, mode::32, mtime_ns::64, ctime_ns::64,
          rest::binary>>,
        true
      )
      when type in 1..4 do
    {:ok,
     %{
       size: size,
       device: device,
       inode: inode,
       links: links,
       type: elem({:regular, :directory, :symlink, :other}, type - 1),
       mode: mode,
       mtime_ns: mtime_ns,
       ctime_ns: ctime_ns
     }, rest}
  end

  def identity(
        <<size::64, device::64, inode::64, links::64, type, mode::32, rest::binary>>,
        false
      )
      when type in 1..4 do
    {:ok,
     %{
       size: size,
       device: device,
       inode: inode,
       links: links,
       type: elem({:regular, :directory, :symlink, :other}, type - 1),
       mode: mode
     }, rest}
  end

  def identity(_, _), do: :error
  def entries(<<>>, 0, acc, _cold?), do: {:ok, Enum.reverse(acc)}

  def entries(<<n::16, name::binary-size(n), rest::binary>>, count, acc, cold?) when count > 0 do
    case identity(rest, cold?) do
      {:ok, id, remaining} ->
        entries(remaining, count - 1, [Map.put(id, :name, name) | acc], cold?)

      _ ->
        :error
    end
  end

  def entries(_, _, _, _), do: :error

  def scope(:root), do: 0
  def scope(:segments), do: 1
  def scope(:verify), do: 2
  def scope(:catalog), do: 2
  def scope(:epochs), do: 3
  def scope(:candidate), do: 4
  def scope(:candidate_segments), do: 5
  def scope(:epoch), do: 6
  def string(bytes), do: <<byte_size(bytes)::16, bytes::binary>>
end
