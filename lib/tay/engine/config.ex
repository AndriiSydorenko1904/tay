defmodule Tay.Engine.Config do
  @moduledoc "Validated, non-persisted Engine configuration. No storage is opened here."
  alias Tay.Event.V2
  alias Tay.Gateway.Config, as: GatewayConfig
  alias Tay.Storage.Recovery
  @environment Mix.env()
  @bytes_per_mebibyte 1_048_576
  @bytes_per_kibibyte 1_024
  @default_rotation_target_bytes 64 * @bytes_per_mebibyte
  @default_insert_payload_bytes 1 * @bytes_per_mebibyte
  @default_insert_args_bytes 256 * @bytes_per_kibibyte
  @default_client_bytes 64 * @bytes_per_mebibyte
  # Shared hard ceiling for bounded Event values and public protocol bodies.
  @max_protocol_payload_bytes 16 * @bytes_per_mebibyte
  @max_rotation_target_bytes 1_024 * @bytes_per_mebibyte
  @default_max_state_bytes 256 * @bytes_per_mebibyte
  # The canonical encoding of an empty arguments object occupies five bytes.
  @minimum_encoded_args_bytes 5
  @minimum_client_slot_bytes 256
  # Admission deadlines are carried as unsigned 32-bit millisecond values.
  @max_caller_timeout_ms 4_294_967_295
  @max_client_slots 65_536
  @group_commit_interval_range 0..1_000
  @execution_batch_range 1..1_024
  @execution_wake_range_ms 1..1_000
  @defaults Map.merge(
              %{
                name: Tay.Engine,
                workers: %{},
                durability: :sync,
                group_commit_interval_ms: 0,
                initialize: :never,
                validated_filesystem: false,
                rotation_target_bytes: @default_rotation_target_bytes,
                storage_timeout: 10_000,
                recovery: [],
                max_insert_payload_bytes: @default_insert_payload_bytes,
                max_insert_args_bytes: @default_insert_args_bytes,
                insert_value_depth: 32,
                insert_value_nodes: 10_000,
                max_state_bytes: @default_max_state_bytes,
                client_slots: 64,
                client_bytes: @default_client_bytes,
                caller_timeout: 5_000,
                execution_batch: 32,
                execution_wake_ms: 1_000,
                start_paused: false,
                rate_limits: [],
                max_history_bytes: :infinity,
                max_segments: :infinity,
                compaction: []
              },
              GatewayConfig.defaults()
            )

  def new(options) do
    allowed =
      Map.keys(@defaults) ++
        [:data_dir, :queues, :max_jobs, :max_state_nodes] ++ test_option_keys()

    with true <- keyword?(options, allowed) || {:error, :invalid_engine_options},
         true <-
           legacy_job_limit?(Keyword.get(options, :max_jobs, 0)) ||
             {:error, :invalid_engine_options},
         true <-
           legacy_state_node_limit?(Keyword.get(options, :max_state_nodes, 0)) ||
             {:error, :invalid_engine_options},
         {:ok, base} <- Tay.Config.load(),
         {:ok, base} <-
           Tay.Config.new(
             Keyword.merge(
               Map.to_list(base) |> Keyword.drop([:__struct__]),
               Keyword.take(options, [:data_dir, :queues])
             )
           ),
         true <- base.data_dir != nil || {:error, :data_dir_required},
         config =
           Map.merge(
             @defaults,
             options |> Keyword.drop([:max_jobs, :max_state_nodes]) |> Map.new()
           ),
         {:ok, config} <- GatewayConfig.resolve(config, base.data_dir),
         {:ok, recovery} <- Recovery.options(config.recovery),
         {:ok, compaction} <- Tay.Engine.CompactionConfig.new(config.compaction),
         {:ok, _} <-
           Tay.Execution.RateLimiter.normalize(
             config.rate_limits,
             Map.new(base.queues, fn {name, _} -> {Atom.to_string(name), name} end)
           ),
         :ok <- validate(Map.put(config, :data_dir, base.data_dir), recovery) do
      queues = Map.new(base.queues, fn {name, _} -> {Atom.to_string(name), name} end)
      queue_limits = Map.new(base.queues, fn {name, limit} -> {Atom.to_string(name), limit} end)
      {:ok, rate_limits} = Tay.Execution.RateLimiter.normalize(config.rate_limits, queues)

      {:ok,
       Map.merge(config, %{
         data_dir: base.data_dir,
         job_durability: base.durability,
         journal_batch: journal_batch(base.journal, options, config),
         queues: queues,
         queue_limits: queue_limits,
         rate_limits: rate_limits,
         execution: execution_enabled(config),
         clock: execution_clock(config),
         recovery: Map.to_list(recovery),
         compaction: compaction,
         value_limits: recovery.event_limits,
         slot_bytes: div(config.client_bytes, config.client_slots),
         candidate_limits: %{
           max_bytes: config.max_state_bytes,
           report_required: true,
           local_worker_keys: MapSet.new(Map.keys(config.workers)),
           result_reserve_bytes:
             if(is_binary(config.executor_socket) or is_integer(config.http_port),
               do: Tay.State.Memory.result_reserve(config.executor_result_bytes),
               else: 0
             )
         }
       })}
    else
      {:error, _} -> {:error, Tay.Error.new(:invalid, :engine_configuration)}
    end
  end

  defp legacy_job_limit?(value), do: is_integer(value) and value >= 0
  defp legacy_state_node_limit?(value), do: is_integer(value) and value >= 0

  defp journal_batch(journal, options, config) do
    if Keyword.has_key?(options, :group_commit_interval_ms) do
      %{
        max_events: config.client_slots,
        interval_ms: config.group_commit_interval_ms
      }
    else
      batch = Keyword.fetch!(journal, :batch)
      %{max_events: batch[:max_events], interval_ms: batch[:interval_ms]}
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
    with :ok <- validate_identity(c),
         :ok <- validate_numeric_limits(c),
         :ok <- validate_execution(c),
         :ok <- validate_transport(c),
         :ok <- validate_storage(c),
         :ok <- validate_payloads(c, r),
         :ok <- validate_test_options(c),
         do: :ok
  end

  defp validate_identity(c) do
    valid_name = is_atom(c.name) and c.name not in [nil, false, true]

    valid_workers =
      is_map(c.workers) and not is_struct(c.workers) and
        Enum.all?(c.workers, fn {key, module} ->
          V2.key?(key) and is_atom(module) and module not in [nil, false, true]
        end)

    valid(valid_name and valid_workers)
  end

  defp validate_numeric_limits(c) do
    positive_fields = [
      :storage_timeout,
      :rotation_target_bytes,
      :client_slots,
      :client_bytes,
      :caller_timeout,
      :insert_value_depth,
      :insert_value_nodes
    ]

    nonnegative_fields = [
      :max_insert_payload_bytes,
      :max_insert_args_bytes,
      :max_state_bytes
    ]

    validate_all([
      Enum.all?(positive_fields, &positive_integer?(c[&1])),
      Enum.all?(nonnegative_fields, &nonnegative_integer?(c[&1])),
      integer_in?(c.group_commit_interval_ms, @group_commit_interval_range),
      c.caller_timeout <= @max_caller_timeout_ms,
      c.client_slots <= @max_client_slots,
      c.client_bytes >= c.client_slots * @minimum_client_slot_bytes
    ])
  end

  defp validate_execution(c) do
    validate_all([
      integer_in?(c.execution_batch, @execution_batch_range),
      integer_in?(c.execution_wake_ms, @execution_wake_range_ms),
      is_boolean(c.start_paused)
    ])
  end

  defp validate_transport(c) do
    GatewayConfig.validate(c, c.data_dir)
  end

  defp validate_storage(c) do
    validate_all([
      limit?(c.max_history_bytes),
      limit?(c.max_segments),
      c.rotation_target_bytes >= Tay.Storage.Segment.min_rotation_bytes(),
      c.rotation_target_bytes <= @max_rotation_target_bytes,
      is_boolean(c.validated_filesystem),
      c.durability in [:write, :sync],
      c.initialize in [:never, :if_missing],
      sync_durability_supported?(c),
      production_durability?(c)
    ])
  end

  defp validate_payloads(c, recovery) do
    validate_all([
      c.max_insert_payload_bytes >= 1,
      c.max_insert_payload_bytes <= recovery.max_decode_payload_bytes,
      c.max_insert_payload_bytes <= recovery.event_limits.binary_bytes,
      c.max_insert_args_bytes >= @minimum_encoded_args_bytes,
      c.max_insert_args_bytes <= @max_protocol_payload_bytes,
      c.insert_value_depth <= recovery.event_limits.depth,
      c.insert_value_nodes <= recovery.event_limits.output_nodes
    ])
  end

  defp validate_test_options(c) do
    clock = Map.get(c, :test_clock, Tay.Execution.Clock)

    validate_all([
      is_boolean(Map.get(c, :test_helper, false)),
      is_boolean(Map.get(c, :test_execution, true)),
      is_atom(clock),
      clock not in [nil, false, true],
      optional_function?(Map.get(c, :test_hook), 1),
      optional_function?(Map.get(c, :test_terminate), 1),
      optional_function?(Map.get(c, :writer_hook), 2)
    ])
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
  defp integer_in?(value, range), do: is_integer(value) and value in range
  defp limit?(:infinity), do: true
  defp limit?(value), do: nonnegative_integer?(value)
  defp optional_function?(nil, _arity), do: true
  defp optional_function?(function, arity), do: is_function(function, arity)

  defp sync_durability_supported?(%{durability: :write}), do: true

  defp sync_durability_supported?(%{durability: :sync, validated_filesystem: validated}),
    do: validated and :os.type() == {:unix, :linux}

  defp valid(true), do: :ok
  defp valid(false), do: {:error, :invalid_engine_options}
  defp validate_all(checks), do: valid(Enum.all?(checks))

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
