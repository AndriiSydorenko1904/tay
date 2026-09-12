defmodule Tay.Storage.Native do
  @moduledoc """
  Internal, versioned filesystem Port protocol. Calls run only in the Port owner.
  Every uncertain operation poisons this connection; it is never retried.
  The helper is the sole holder of locks and writable descriptors.
  """
  @test Mix.env() == :test
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
    fault: 240
  }
  defstruct [:port, :owner, :facts, :generation, :deadline, timeout: 10_000]
  @type t :: %__MODULE__{}

  @doc "Acquires only existing ownership objects; no creation or sync is allowed."
  def open_existing(path, options \\ []) do
    allowed =
      [
        :durability,
        :validated_filesystem,
        :test_helper,
        :timeout,
        :max_directory_entries,
        :deadline
      ] ++ if(@test, do: [:test_before_acquire], else: [])

    if valid_open_options?(path, options) and Path.expand(path) != "/" and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
         is_integer(Keyword.get(options, :max_directory_entries, 100_000)) and
         Keyword.get(options, :max_directory_entries, 100_000) in 1..4_294_967_295 and
         (is_nil(Keyword.get(options, :deadline)) or is_integer(Keyword.get(options, :deadline))) do
      do_open(path, options, :acquire_existing)
    else
      {:error, %{kind: :native_argument, reason: :invalid_existing_options}}
    end
  end

  @doc false
  def inspection?(native) do
    native.owner == self() and Process.get({__MODULE__, native.port, :capability}) == :inspection
  end

  @doc "Promotes this continuously held inspection session; never reacquires ownership."
  def enable_mutations(native) do
    case empty(native, :enable_mutations) do
      :ok ->
        Process.put({__MODULE__, native.port, :capability}, :mutation)
        :ok

      error ->
        close(native)
        error
    end
  end

  def open(path, options \\ []) do
    if valid_open_options?(path, options) do
      do_open(path, options)
    else
      {:error, %{kind: :native_argument, reason: :invalid_open_options}}
    end
  end

  defp valid_open_options?(path, options) do
    is_binary(path) and byte_size(path) in 1..4095 and String.valid?(path) and
      not String.contains?(path, <<0>>) and Path.type(path) == :absolute and
      Keyword.keyword?(options) and Keyword.get(options, :durability, :sync) in [:write, :sync] and
      is_boolean(Keyword.get(options, :validated_filesystem, false)) and
      is_boolean(Keyword.get(options, :test_helper, false)) and
      is_integer(Keyword.get(options, :timeout, 10_000)) and
      Keyword.get(options, :timeout, 10_000) > 0
  end

  defp do_open(path, options, operation \\ :acquire) do
    test = @test and Keyword.get(options, :test_helper, false)

    executable =
      Application.app_dir(
        :tay,
        "priv/" <> if(test, do: "tay_storage_helper_test", else: "tay_storage_helper")
      )

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:packet, 4}
      ])

    native = %__MODULE__{
      port: port,
      owner: self(),
      generation: make_ref(),
      deadline: Keyword.get(options, :deadline),
      timeout: Keyword.get(options, :timeout, 10_000)
    }

    mode = if Keyword.get(options, :durability, :sync) == :sync, do: 1, else: 0
    validated = if Keyword.get(options, :validated_filesystem, false), do: 1, else: 0

    budget =
      if operation == :acquire_existing,
        do: <<Keyword.get(options, :max_directory_entries, 100_000)::32>>,
        else: <<>>

    result =
      with :ok <- before_acquire(native, options),
           do:
             request(native, operation, <<mode, validated, budget::binary, string(path)::binary>>)

    case result do
      {:ok, <<created, filesystem::64, pid::64>>, 0}
      when operation == :acquire or (created == 0 and pid > 0) ->
        Process.put(
          {__MODULE__, port, :capability},
          if(operation == :acquire_existing, do: :inspection, else: :mutation)
        )

        {:ok, %{native | facts: %{created: created == 1, filesystem: filesystem, os_pid: pid}}}

      {:error, _} = error ->
        shutdown(native)
        error

      _ ->
        uncertain(native, :invalid_acquire_reply)
    end
  rescue
    error -> {:error, %{kind: :native_start, reason: Exception.message(error)}}
  end

  if @test do
    defp before_acquire(native, options) do
      case Keyword.get(options, :test_before_acquire) do
        nil -> :ok
        fun when is_function(fun, 1) -> fun.(native)
        _ -> {:error, %{kind: :native_argument, reason: :invalid_acquire_hook}}
      end
    catch
      _, _ -> {:error, %{kind: :native_argument, reason: :failed_acquire_hook}}
    end
  else
    defp before_acquire(_, _), do: :ok
  end

  def close(%__MODULE__{port: port, owner: owner}) when owner == self() do
    if Port.info(port) != nil, do: Port.close(port)
    Process.put({__MODULE__, port}, :closed)
    Process.delete({__MODULE__, port, :capability})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def close(%__MODULE__{}), do: {:error, %{kind: :native_owner, reason: :not_port_owner}}

  def shutdown(native) do
    if self() == native.owner and Process.get({__MODULE__, native.port}) == nil and
         Port.info(native.port) != nil do
      result = empty(%{native | deadline: nil}, :shutdown)
      close(native)
      result
    else
      close(native)
    end
  end

  def list(native, scope) do
    case request(native, :list, <<scope(scope)>>) do
      {:ok, <<count::32, bytes::binary>>, 0} ->
        case entries(bytes, count, []) do
          {:ok, entries} -> {:ok, entries}
          _ -> uncertain(native, :invalid_directory_reply)
        end

      {:error, _} = error ->
        error

      _ ->
        uncertain(native, :invalid_directory_reply)
    end
  end

  def mkdir_segments(native), do: empty(native, :mkdir)

  def open_read(native, scope, name),
    do: identity_request(native, :open_read, <<scope(scope), string(name)::binary>>)

  def read(native, offset, length) when offset >= 0 and length in 0..16_777_244 do
    case request(native, :read, <<offset::64, length::32>>) do
      {:ok, bytes, 0} when byte_size(bytes) <= length -> {:ok, bytes}
      {:error, _} = error -> error
      _ -> uncertain(native, :invalid_read_reply)
    end
  end

  def close_read(native), do: empty(native, :close_read)
  def sync_read(native), do: empty(native, :sync_read)

  def create_stage(native, scope, name),
    do: identity_request(native, :create_stage, <<scope(scope), string(name)::binary>>)

  def open_active(native, name, identity),
    do:
      identity_request(
        native,
        :open_active,
        <<string(name)::binary, identity.size::64, identity.device::64, identity.inode::64>>
      )

  def write(native, offset, bytes) when is_binary(bytes) do
    case request(native, :write, <<offset::64, bytes::binary>>) do
      {:ok, metadata, written} when written == byte_size(bytes) ->
        case identity(metadata) do
          {:ok, id, <<>>} -> {:ok, %{written: written, identity: id}}
          _ -> uncertain(native, :invalid_write_reply)
        end

      {:error, _} = error ->
        error

      _ ->
        uncertain(native, :invalid_write_length)
    end
  end

  def sync(native), do: empty(native, :sync)
  def close_write(native), do: empty(native, :close_write)
  def sync_dir(native, scope), do: empty(native, :sync_dir, <<scope(scope)>>)
  def check(native), do: empty(native, :check)

  def publish(native, scope, source, target, identity),
    do:
      empty(
        native,
        :publish,
        <<scope(scope), string(source)::binary, string(target)::binary, identity.device::64,
          identity.inode::64>>
      )

  def info(native) do
    case request(native, :info, <<>>) do
      {:ok, <<pid::64, writable, readable, filesystem::64, ancestor_syncs::32>>, 0} ->
        {:ok,
         %{
           os_pid: pid,
           writable: writable,
           readable: readable == 1,
           filesystem: filesystem,
           ancestor_syncs: ancestor_syncs
         }}

      {:error, _} = error ->
        error

      _ ->
        uncertain(native, :invalid_info_reply)
    end
  end

  if @test do
    def fault(native, operation, occurrence, action, errno \\ 5, count \\ 0) do
      target =
        Map.get(
          %{
            promotion_ancestor: 241,
            promotion_lock: 242,
            promotion_root: 243,
            promotion_segments: 244
          },
          operation
        ) || Map.fetch!(@ops, operation)

      code =
        %{
          error: 1,
          short: 2,
          crash_after: 3,
          drop_reply: 4,
          crash_before: 5,
          lose_lock: 6,
          invalid_reply: 7,
          syscall_error: 8
        }[
          action
        ]

      empty(
        native,
        :fault,
        <<target, occurrence::32, code, errno::32, count::64>>
      )
    end
  end

  defp empty(native, op, body \\ <<>>) do
    case request(native, op, body) do
      {:ok, <<>>, 0} -> :ok
      {:error, _} = error -> error
      _ -> uncertain(native, {:invalid_empty_reply, op})
    end
  end

  defp identity_request(native, op, body) do
    case request(native, op, body) do
      {:ok, bytes, 0} ->
        case identity(bytes) do
          {:ok, id, <<>>} -> {:ok, id}
          _ -> uncertain(native, {:invalid_identity_reply, op})
        end

      {:error, _} = error ->
        error

      _ ->
        uncertain(native, {:invalid_identity_reply, op})
    end
  end

  defp identity(<<size::64, device::64, inode::64, links::64, type, mode::32, rest::binary>>)
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

  defp identity(_), do: :error
  defp entries(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp entries(<<n::16, name::binary-size(n), rest::binary>>, count, acc) when count > 0 do
    case identity(rest) do
      {:ok, id, remaining} -> entries(remaining, count - 1, [Map.put(id, :name, name) | acc])
      _ -> :error
    end
  end

  defp entries(_, _, _), do: :error
  defp scope(:root), do: 0
  defp scope(:segments), do: 1
  defp string(bytes), do: <<byte_size(bytes)::16, bytes::binary>>

  defp request(native, operation, body) do
    cond do
      self() != native.owner ->
        {:error, %{kind: :native_owner, reason: :not_port_owner}}

      Process.get({__MODULE__, native.port}) != nil ->
        {:error, %{kind: :uncertain, reason: :poisoned_connection}}

      byte_size(body) > 16_777_244 + 4096 ->
        {:error, %{kind: :native_argument, reason: :packet_too_large}}

      is_integer(native.deadline) and System.monotonic_time(:millisecond) >= native.deadline ->
        {:error, %{kind: :resource_limit, reason: :deadline}}

      true ->
        op = Map.fetch!(@ops, operation)
        id = System.unique_integer([:positive, :monotonic])
        port = native.port

        timeout =
          if is_integer(native.deadline),
            do:
              min(native.timeout, max(native.deadline - System.monotonic_time(:millisecond), 1)),
            else: native.timeout

        try do
          true = Port.command(port, <<1, op, id::64, body::binary>>)

          receive do
            {^port, {:data, <<1, ^op, ^id::64, 0, 0::32, written::64, reply::binary>>}} ->
              {:ok, reply, written}

            {^port, {:data, <<1, ^op, ^id::64, 1, errno::32, written::64, reason::binary>>}} ->
              {:error,
               %{
                 kind: :native_io,
                 operation: operation,
                 errno: errno,
                 reason: reason,
                 bytes_written:
                   if(written == 18_446_744_073_709_551_615, do: :unknown, else: written)
               }}

            {^port, {:data, _}} ->
              uncertain(native, :invalid_reply)

            {^port, {:exit_status, status}} ->
              uncertain(native, {:helper_exit, status})

            {:EXIT, ^port, reason} ->
              uncertain(native, {:port_exit, reason})
          after
            timeout -> uncertain(native, {:timeout, operation})
          end
        rescue
          ArgumentError -> uncertain(native, :connection_lost)
        end
    end
  end

  defp uncertain(native, reason) do
    close(native)
    {:error, %{kind: :uncertain, reason: reason}}
  end
end
