defmodule Tay.Engine.Config do
  @moduledoc "Validated, non-persisted Engine configuration. No storage is opened here."
  alias Tay.Event.V2
  alias Tay.Gateway.Config, as: GatewayConfig
  alias Tay.Storage.Recovery
  @environment Mix.env()
  @bytes_per_mebibyte 1_048_576
  @default_client_bytes 64 * @bytes_per_mebibyte
  @default_max_state_bytes 256 * @bytes_per_mebibyte
  # Admission deadlines are carried as unsigned 32-bit millisecond values.
  @max_caller_timeout_ms Tay.Limits.uint32_max()
  @max_client_slots 65_536
  @defaults Map.merge(
              %{
                name: Tay.Engine,
                workers: %{},
                durability: :sync,
                initialize: :never,
                validated_filesystem: false,
                storage_timeout: 10_000,
                recovery: [],
                max_state_bytes: @default_max_state_bytes,
                client_slots: 64,
                client_bytes: @default_client_bytes,
                caller_timeout: 5_000,
                start_paused: false,
                rate_limits: [],
                max_history_bytes: :infinity,
                compaction: []
              },
              GatewayConfig.defaults()
            )

  @allowed_defaults if(@environment == :prod,
                      do: Map.keys(@defaults) -- [:durability],
                      else: Map.keys(@defaults)
                    )

  def new(options) do
    allowed = @allowed_defaults ++ [:data_dir, :queues] ++ test_option_keys()

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
         config =
           Map.merge(
             @defaults,
             Map.new(options)
           ),
         {:ok, config} <- GatewayConfig.resolve(config, base.data_dir),
         {:ok, recovery} <- Recovery.options(config.recovery),
         {:ok, compaction} <- Tay.Engine.CompactionConfig.new(config.compaction),
         {:ok, _} <-
           Tay.Execution.RateLimiter.normalize(
             config.rate_limits,
             Map.new(base.queues, fn {name, _} -> {Atom.to_string(name), name} end)
           ),
         :ok <- validate(Map.put(config, :data_dir, base.data_dir)) do
      queues = Map.new(base.queues, fn {name, _} -> {Atom.to_string(name), name} end)
      queue_limits = Map.new(base.queues, fn {name, limit} -> {Atom.to_string(name), limit} end)
      {:ok, rate_limits} = Tay.Execution.RateLimiter.normalize(config.rate_limits, queues)

      {:ok,
       Map.merge(config, %{
         data_dir: base.data_dir,
         job_durability: base.durability,
         queues: queues,
         queue_limits: queue_limits,
         rate_limits: rate_limits,
         execution: execution_enabled(config),
         clock: execution_clock(config),
         recovery: Map.to_list(recovery),
         compaction: compaction,
         value_limits: Tay.Event.Value.defaults(),
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

  def storage(config) do
    [
      data_dir: config.data_dir,
      durability: config.durability,
      validated_filesystem: config.validated_filesystem,
      timeout: config.storage_timeout
    ] ++ test_storage_options(config)
  end

  def keyword?(options, allowed),
    do:
      Keyword.keyword?(options) and
        length(options) == length(Enum.uniq(Keyword.keys(options))) and
        Enum.all?(Keyword.keys(options), &(&1 in allowed))

  defp validate(c) do
    with :ok <- validate_identity(c),
         :ok <- validate_numeric_limits(c),
         :ok <- validate_execution(c),
         :ok <- validate_transport(c),
         :ok <- validate_storage(c),
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
      :client_slots,
      :client_bytes,
      :caller_timeout
    ]

    nonnegative_fields = [
      :max_state_bytes
    ]

    validate_all([
      Enum.all?(positive_fields, &positive_integer?(c[&1])),
      Enum.all?(nonnegative_fields, &nonnegative_integer?(c[&1])),
      c.caller_timeout <= @max_caller_timeout_ms,
      c.client_slots <= @max_client_slots
    ])
  end

  defp validate_execution(c) do
    validate_all([
      is_boolean(c.start_paused)
    ])
  end

  defp validate_transport(c) do
    GatewayConfig.validate(c, c.data_dir)
  end

  defp validate_storage(c) do
    validate_all([
      limit?(c.max_history_bytes),
      is_boolean(c.validated_filesystem),
      c.durability in [:write, :sync],
      c.initialize in [:never, :if_missing],
      sync_durability_supported?(c),
      production_durability?(c)
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
