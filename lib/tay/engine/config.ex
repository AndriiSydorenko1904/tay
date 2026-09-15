defmodule Tay.Engine.Config do
  @moduledoc "Validated, non-persisted Engine configuration. No storage is opened here."
  alias Tay.Event.V1
  alias Tay.Executor.SocketPath
  alias Tay.Storage.Recovery
  @environment Mix.env()
  @defaults %{
    name: Tay.Engine,
    workers: %{},
    durability: :sync,
    validated_filesystem: false,
    rotation_target_bytes: 67_108_864,
    storage_timeout: 10_000,
    recovery: [],
    max_insert_payload_bytes: 1_048_576,
    max_insert_args_bytes: 262_144,
    insert_value_depth: 32,
    insert_value_nodes: 10_000,
    max_jobs: 100_000,
    max_state_bytes: 268_435_456,
    max_state_nodes: 2_000_000,
    client_slots: 64,
    client_bytes: 67_108_864,
    caller_timeout: 5_000,
    execution_batch: 32,
    execution_wake_ms: 1_000,
    # A local Protocol v1 listener is automatic by default. Set an absolute
    # path to override discovery, or explicitly pass nil to disable it.
    executor_socket: :auto,
    executor_socket_mode: 0o600,
    executor_max_frame_bytes: 1_048_576,
    executor_max_connections: 128,
    executor_max_tasks_per_connection: 256,
    executor_result_bytes: 65_536,
    executor_error_bytes: 8_192,
    executor_max_results: 10_000,
    start_paused: false,
    max_history_bytes: :infinity,
    max_segments: :infinity,
    compaction: []
  }

  def new(options) do
    allowed = Map.keys(@defaults) ++ [:data_dir, :queues] ++ test_option_keys()

    with true <- keyword?(options, allowed) || {:error, :invalid_engine_options},
         {:ok, base} <- Tay.Config.load(),
         {:ok, base} <-
           Tay.Config.new(
             Keyword.merge(
               Map.to_list(base) |> Keyword.drop([:__struct__]),
               Keyword.take(options, [:data_dir, :queues])
             )
           ),
         true <- base.data_dir != nil || {:error, :data_dir_required},
         config = Map.merge(@defaults, Map.new(options)),
         {:ok, socket} <- SocketPath.resolve(config.executor_socket),
         config =
           config
           |> Map.put(:executor_socket, socket.path)
           |> Map.put(:executor_socket_private_directory, socket.private_directory),
         {:ok, recovery} <- Recovery.options(config.recovery),
         {:ok, compaction} <- Tay.Engine.CompactionConfig.new(config.compaction),
         :ok <- validate(config, recovery) do
      queues = Map.new(base.queues, fn {name, _} -> {Atom.to_string(name), name} end)
      queue_limits = Map.new(base.queues, fn {name, limit} -> {Atom.to_string(name), limit} end)

      {:ok,
       Map.merge(config, %{
         data_dir: base.data_dir,
         queues: queues,
         queue_limits: queue_limits,
         execution: execution_enabled(config),
         clock: execution_clock(config),
         recovery: Map.to_list(recovery),
         compaction: compaction,
         value_limits: recovery.event_limits,
         slot_bytes: div(config.client_bytes, config.client_slots),
         candidate_limits: %{
           max_jobs: config.max_jobs,
           max_bytes: config.max_state_bytes,
           max_nodes: config.max_state_nodes
         }
       })}
    else
      {:error, _} -> {:error, Tay.Error.new(:invalid, :engine_configuration)}
    end
  end

  def storage(config) do
    [
      data_dir: config.data_dir,
      durability: config.durability,
      validated_filesystem: config.validated_filesystem,
      rotation_target_bytes: config.rotation_target_bytes,
      timeout: config.storage_timeout
    ] ++ test_storage_options(config)
  end

  def keyword?(options, allowed),
    do:
      Keyword.keyword?(options) and
        length(options) == length(Enum.uniq(Keyword.keys(options))) and
        Enum.all?(Keyword.keys(options), &(&1 in allowed))

  defp validate(c, r) do
    positive = [
      :storage_timeout,
      :rotation_target_bytes,
      :client_slots,
      :client_bytes,
      :caller_timeout,
      :insert_value_depth,
      :insert_value_nodes,
      :executor_max_frame_bytes,
      :executor_max_connections,
      :executor_max_tasks_per_connection,
      :executor_result_bytes,
      :executor_error_bytes,
      :executor_max_results
    ]

    nonnegative = [
      :max_insert_payload_bytes,
      :max_insert_args_bytes,
      :max_jobs,
      :max_state_bytes,
      :max_state_nodes
    ]

    valid =
      is_atom(c.name) and c.name not in [nil, false, true] and
        is_map(c.workers) and not is_struct(c.workers) and
        Enum.all?(c.workers, fn {key, mod} ->
          V1.key?(key) and is_atom(mod) and mod not in [nil, false, true]
        end) and Enum.all?(positive, &(is_integer(c[&1]) and c[&1] > 0)) and
        Enum.all?(nonnegative, &(is_integer(c[&1]) and c[&1] >= 0)) and
        c.caller_timeout <= 4_294_967_295 and c.client_slots <= 65_536 and
        is_integer(c.execution_batch) and c.execution_batch in 1..1_024 and
        is_integer(c.execution_wake_ms) and c.execution_wake_ms in 1..1_000 and
        executor_socket?(c.executor_socket) and c.executor_socket_mode in [0o600, 0o660] and
        is_boolean(c.executor_socket_private_directory) and
        executor_socket_outside_data_dir?(c.executor_socket, c.data_dir) and
        c.executor_max_frame_bytes <= 16_777_216 and
        c.executor_result_bytes <= c.executor_max_frame_bytes and
        c.executor_error_bytes <= c.executor_max_frame_bytes and
        is_boolean(c.start_paused) and
        Enum.all?([c.max_history_bytes, c.max_segments], fn limit ->
          limit == :infinity or (is_integer(limit) and limit >= 0)
        end) and
        c.client_bytes >= c.client_slots * 256 and
        c.rotation_target_bytes >= Tay.Storage.Segment.min_rotation_bytes() and
        c.rotation_target_bytes <= 1_073_741_824 and
        is_boolean(c.validated_filesystem) and c.durability in [:write, :sync] and
        (c.durability != :sync or (c.validated_filesystem and :os.type() == {:unix, :linux})) and
        production_durability?(c) and
        c.max_insert_payload_bytes <= r.max_decode_payload_bytes and
        c.max_insert_payload_bytes <= r.event_limits.binary_bytes and
        c.max_insert_payload_bytes >= 1 and c.max_insert_args_bytes >= 5 and
        c.max_insert_args_bytes <= 16_777_216 and
        c.insert_value_depth <= r.event_limits.depth and
        c.insert_value_nodes <= r.event_limits.output_nodes and
        is_boolean(Map.get(c, :test_helper, false)) and
        is_boolean(Map.get(c, :test_execution, true)) and
        is_atom(Map.get(c, :test_clock, Tay.Execution.Clock)) and
        Map.get(c, :test_clock, Tay.Execution.Clock) not in [nil, false, true] and
        (is_nil(Map.get(c, :test_hook)) or is_function(c.test_hook, 1)) and
        (is_nil(Map.get(c, :test_terminate)) or is_function(c.test_terminate, 1)) and
        (is_nil(Map.get(c, :writer_hook)) or is_function(c.writer_hook, 2))

    if valid, do: :ok, else: {:error, :invalid_engine_options}
  end

  defp executor_socket?(nil), do: true

  defp executor_socket?(path) when is_binary(path) do
    path != "" and byte_size(path) <= 100 and String.valid?(path) and
      not String.contains?(path, <<0>>) and Path.type(path) == :absolute
  end

  # Storage owns and validates every entry below data_dir. Keep a runtime Unix
  # socket beside it, never inside it, so recovery cannot mistake it for foreign
  # storage state or require a weakened directory scan.
  defp executor_socket_outside_data_dir?(nil, _data_dir), do: true

  defp executor_socket_outside_data_dir?(socket, data_dir)
       when is_binary(socket) and is_binary(data_dir) do
    socket = Path.expand(socket)
    data_dir = Path.expand(data_dir)
    socket != data_dir and not String.starts_with?(socket, data_dir <> "/")
  end

  defp executor_socket_outside_data_dir?(_, _), do: false

  # Compile only the applicable branch. Test hooks remain unavailable to
  # production configuration and no environment check runs on a live request.
  if @environment == :test do
    defp test_option_keys,
      do: [:test_helper, :test_hook, :writer_hook, :test_execution, :test_clock, :test_terminate]

    defp execution_enabled(config), do: Map.get(config, :test_execution, true)
    defp execution_clock(config), do: Map.get(config, :test_clock, Tay.Execution.Clock)

    defp test_storage_options(config),
      do: [
        test_helper: Map.get(config, :test_helper, false),
        on_transition: Map.get(config, :writer_hook)
      ]
  else
    defp test_option_keys, do: []
    defp execution_enabled(_config), do: true
    defp execution_clock(_config), do: Tay.Execution.Clock
    defp test_storage_options(_config), do: []
  end

  if @environment == :prod do
    defp production_durability?(config), do: config.durability == :sync
  else
    defp production_durability?(_config), do: true
  end
end
