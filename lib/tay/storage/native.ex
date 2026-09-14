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
    v2_adopt_v1: 32,
    v2_publish_current: 33,
    v2_space: 34,
    v2_restore_v1: 35,
    v2_clear_adoption: 36,
    v2_reclaim: 37,
    fault: 240
  }
  defstruct [:port, :owner, :facts, :generation, :deadline, :cold?, timeout: 10_000]
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
      ] ++ test_existing_option_keys()

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

  @doc false
  def open_cold_target(source, destination, catalog, verify_catalog, options \\ []) do
    with true <- valid_cold_source?(source),
         true <- valid_open_options?(destination, options),
         true <- valid_path?(catalog),
         true <- is_nil(verify_catalog) or valid_path?(verify_catalog),
         true <- valid_cold_options?(options) do
      native = new_native(options)
      mode = if Keyword.get(options, :durability, :sync) == :sync, do: 1, else: 0
      validated = if Keyword.get(options, :validated_filesystem, false), do: 1, else: 0

      body =
        <<mode, validated, source.root.device::64, source.root.inode::64,
          source.segments.device::64, source.segments.inode::64,
          string(Path.dirname(destination))::binary, string(Path.basename(destination))::binary,
          string(Path.dirname(catalog))::binary, string(Path.basename(catalog))::binary,
          cold_verify(verify_catalog)::binary>>

      case request(native, :cold_target_open, body) do
        {:ok, <<filesystem::64>>, 0} ->
          {:ok, %{native | facts: %{filesystem: filesystem}, cold?: true}}

        {:error, _} = error ->
          shutdown(native)
          error

        _ ->
          uncertain(native, :invalid_cold_target_reply)
      end
    else
      _ -> {:error, %{kind: :native_argument, reason: :invalid_cold_target_options}}
    end
  end

  defp valid_open_options?(path, options) do
    valid_path?(path) and
      Keyword.keyword?(options) and Keyword.get(options, :durability, :sync) in [:write, :sync] and
      is_boolean(Keyword.get(options, :validated_filesystem, false)) and
      is_boolean(Keyword.get(options, :test_helper, false)) and
      is_integer(Keyword.get(options, :timeout, 10_000)) and
      Keyword.get(options, :timeout, 10_000) > 0
  end

  defp valid_path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..4095 and String.valid?(path) and
        not String.contains?(path, <<0>>) and Path.type(path) == :absolute

  defp valid_cold_source?(%{root: root, segments: segments}) do
    valid_identity?(root) and valid_identity?(segments)
  end

  defp valid_cold_source?(_), do: false

  defp valid_identity?(%{device: device, inode: inode}),
    do: is_integer(device) and device >= 0 and is_integer(inode) and inode >= 0

  defp valid_identity?(_), do: false

  defp valid_cold_options?(options) do
    allowed = [:durability, :validated_filesystem, :test_helper, :timeout]

    Keyword.keyword?(options) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(Keyword.keys(options), &(&1 in allowed))
  end

  defp do_open(path, options, operation \\ :acquire) do
    native = new_native(options)
    port = native.port

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

  defp new_native(options) do
    executable = Application.app_dir(:tay, "priv/" <> helper_name(options))

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:packet, 4}
      ])

    %__MODULE__{
      port: port,
      owner: self(),
      generation: make_ref(),
      deadline: Keyword.get(options, :deadline),
      timeout: Keyword.get(options, :timeout, 10_000)
    }
  end

  if @test do
    defp test_existing_option_keys, do: [:test_before_acquire]

    defp helper_name(options) do
      if Keyword.get(options, :test_helper, false),
        do: "tay_storage_helper_test",
        else: "tay_storage_helper"
    end

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
    defp test_existing_option_keys, do: []
    defp helper_name(_options), do: "tay_storage_helper"
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
        case entries(bytes, count, [], false) do
          {:ok, entries} -> {:ok, entries}
          _ -> uncertain(native, :invalid_directory_reply)
        end

      {:error, _} = error ->
        error

      _ ->
        uncertain(native, :invalid_directory_reply)
    end
  end

  @doc false
  def cold_source(native) do
    case empty(native, :cold_source) do
      :ok ->
        Process.put({__MODULE__, native.port, :cold_source}, true)
        :ok

      error ->
        error
    end
  end

  @doc false
  def cold_list(native, scope, remaining)
      when is_integer(remaining) and remaining in 1..4_294_967_295 do
    case request(native, :cold_list, <<scope(scope)::8, remaining::32>>) do
      {:ok, <<count::32, bytes::binary>>, 0} ->
        case entries(bytes, count, [], true) do
          {:ok, entries} -> {:ok, entries}
          _ -> uncertain(native, :invalid_directory_reply)
        end

      {:error, _} = error ->
        error

      _ ->
        uncertain(native, :invalid_directory_reply)
    end
  end

  def cold_list(_native, _scope, _remaining),
    do: {:error, %{kind: :native_argument, reason: :invalid_cold_list_limit}}

  @doc false
  def cold_create_stage(native, name), do: empty(native, :cold_stage_create, string(name))

  @doc false
  def cold_open_write(native, scope, name, lock \\ false) when is_boolean(lock),
    do:
      identity_request(
        native,
        :cold_open_write,
        <<scope(scope), if(lock, do: 1, else: 0), string(name)::binary>>
      )

  @doc false
  def cold_sync_staging(native), do: empty(native, :cold_sync_staging)
  @doc false
  def cold_publish(native), do: empty(native, :cold_publish)
  @doc false
  def cold_sync_catalog(native), do: empty(native, :cold_sync_catalog)
  @doc false
  def cold_check(native), do: empty(native, :cold_check)

  def mkdir_segments(native), do: empty(native, :mkdir)

  @doc "Pins the CURRENT-named epoch and its mutable segments directory."
  def v2_select(native, epoch_id) when is_binary(epoch_id) and byte_size(epoch_id) == 16,
    do: empty(native, :v2_select, string("e-" <> Base.encode16(epoch_id, case: :lower)))

  def v2_select(_, _), do: {:error, %{kind: :native_argument, reason: :epoch_id}}

  @doc "Creates a private candidate epoch and its segments directory under the held lock."
  def v2_begin(native, nonce) when is_binary(nonce) and byte_size(nonce) == 16,
    do:
      empty(
        native,
        :v2_begin,
        string(".tay-candidate-" <> Base.encode16(nonce, case: :lower) <> ".tmp")
      )

  def v2_begin(_, _), do: {:error, %{kind: :native_argument, reason: :candidate_nonce}}

  def v2_publish_epoch(native, epoch_id)
      when is_binary(epoch_id) and byte_size(epoch_id) == 16,
      do: empty(native, :v2_publish_epoch, string("e-" <> Base.encode16(epoch_id, case: :lower)))

  def v2_publish_epoch(_, _), do: {:error, %{kind: :native_argument, reason: :epoch_id}}

  def v2_adopt_v1(native, nonce) when is_binary(nonce) and byte_size(nonce) == 16,
    do: empty(native, :v2_adopt_v1, string("legacy-" <> Base.encode16(nonce, case: :lower)))

  def v2_adopt_v1(_, _), do: {:error, %{kind: :native_argument, reason: :adoption_nonce}}

  @doc "Restores the exact intent-named V1 source when CURRENT is absent."
  def v2_restore_v1(native, nonce) when is_binary(nonce) and byte_size(nonce) == 16,
    do: empty(native, :v2_restore_v1, string("legacy-" <> Base.encode16(nonce, case: :lower)))

  def v2_restore_v1(_, _), do: {:error, %{kind: :native_argument, reason: :adoption_nonce}}

  def v2_clear_adoption(native), do: empty(native, :v2_clear_adoption)

  def v2_publish_current(native, stage, source, previous) do
    if is_binary(stage) and Regex.match?(~r/\A\.tay-current-[0-9a-f]{32}\.tmp\z/, stage) and
         valid_identity?(source) and (is_nil(previous) or valid_identity?(previous)) do
      old = previous || %{device: 0, inode: 0}

      empty(
        native,
        :v2_publish_current,
        <<string(stage)::binary, source.device::64, source.inode::64, old.device::64,
          old.inode::64>>
      )
    else
      {:error, %{kind: :native_argument, reason: :current_publication}}
    end
  end

  def v2_space(native) do
    case request(native, :v2_space, <<>>) do
      {:ok, <<free::64>>, 0} -> {:ok, free}
      {:error, _} = error -> error
      _ -> uncertain(native, :invalid_v2_space_reply)
    end
  end

  @doc "Unlinks only a verified non-CURRENT predecessor via pinned descriptors."
  def v2_reclaim(native, target, current, intent \\ nil)

  def v2_reclaim(native, target, current, intent)
      when is_binary(target) and is_binary(current) and byte_size(current) == 76 and
             (is_nil(intent) or (is_binary(intent) and byte_size(intent) == 28)) do
    body = <<string(target)::binary, current::binary, if(intent, do: 1, else: 0)>>
    body = if intent, do: <<body::binary, intent::binary>>, else: body

    case request(native, :v2_reclaim, body) do
      {:ok, <<bytes::64>>, 0} -> {:ok, bytes}
      {:error, _} = error -> error
      _ -> uncertain(native, :invalid_reclaim_reply)
    end
  end

  def v2_reclaim(_, _, _, _), do: {:error, %{kind: :native_argument, reason: :reclaim}}

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
        case identity(metadata, cold?(native)) do
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
      {:ok,
       <<pid::64, writable, readable, filesystem::64, ancestor_syncs::32, root_device::64,
         root_inode::64, segments_device::64, segments_inode::64>>, 0} ->
        {:ok,
         %{
           os_pid: pid,
           writable: writable,
           readable: readable == 1,
           filesystem: filesystem,
           ancestor_syncs: ancestor_syncs,
           root: %{device: root_device, inode: root_inode},
           segments: %{device: segments_device, inode: segments_inode}
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
            promotion_segments: 244,
            v2_epochs_root_sync: 245,
            v2_candidate_parent_sync: 246,
            v2_candidate_directory_sync: 247,
            v2_epoch_segments_sync: 248,
            v2_epoch_directory_sync: 249,
            v2_epoch_parent_sync: 250,
            v2_adoption_root_sync: 251,
            v2_adoption_epochs_sync: 252,
            v2_current_root_sync: 253,
            v2_restore_epochs_sync: 254,
            v2_restore_root_sync: 255,
            v2_rollback_marker_sync: 256,
            v2_rollback_intent_sync: 257
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
        case identity(bytes, cold?(native)) do
          {:ok, id, <<>>} -> {:ok, id}
          _ -> uncertain(native, {:invalid_identity_reply, op})
        end

      {:error, _} = error ->
        error

      _ ->
        uncertain(native, {:invalid_identity_reply, op})
    end
  end

  defp identity(
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

  defp identity(
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

  defp identity(_, _), do: :error
  defp entries(<<>>, 0, acc, _cold?), do: {:ok, Enum.reverse(acc)}

  defp entries(<<n::16, name::binary-size(n), rest::binary>>, count, acc, cold?) when count > 0 do
    case identity(rest, cold?) do
      {:ok, id, remaining} ->
        entries(remaining, count - 1, [Map.put(id, :name, name) | acc], cold?)

      _ ->
        :error
    end
  end

  defp entries(_, _, _, _), do: :error

  defp cold?(native),
    do: native.cold? || Process.get({__MODULE__, native.port, :cold_source}) == true

  defp scope(:root), do: 0
  defp scope(:segments), do: 1
  defp scope(:verify), do: 2
  defp scope(:catalog), do: 2
  defp scope(:epochs), do: 3
  defp scope(:candidate), do: 4
  defp scope(:candidate_segments), do: 5
  defp scope(:epoch), do: 6
  defp string(bytes), do: <<byte_size(bytes)::16, bytes::binary>>

  defp cold_verify(nil), do: <<0>>

  defp cold_verify(path),
    do: <<1, string(Path.dirname(path))::binary, string(Path.basename(path))::binary>>

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
