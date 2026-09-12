defmodule Tay.Engine.Config do
  @moduledoc "Validated, non-persisted Engine configuration. No storage is opened here."
  alias Tay.Event.V1
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
    start_paused: false,
    max_history_bytes: :infinity,
    max_segments: :infinity
  }

  def new(options) do
    allowed =
      Map.keys(@defaults) ++
        [:data_dir, :queues] ++
        if(@environment == :test,
          do: [
            :test_helper,
            :test_hook,
            :writer_hook,
            :test_execution,
            :test_clock,
            :test_terminate
          ],
          else: []
        )

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
         {:ok, recovery} <- Recovery.options(config.recovery),
         :ok <- validate(config, recovery) do
      queues = Map.new(base.queues, fn {name, _} -> {Atom.to_string(name), name} end)
      queue_limits = Map.new(base.queues, fn {name, limit} -> {Atom.to_string(name), limit} end)

      {:ok,
       Map.merge(config, %{
         data_dir: base.data_dir,
         queues: queues,
         queue_limits: queue_limits,
         execution:
           if(@environment == :test, do: Map.get(config, :test_execution, true), else: true),
         clock:
           if(@environment == :test,
             do: Map.get(config, :test_clock, Tay.Execution.Clock),
             else: Tay.Execution.Clock
           ),
         recovery: Map.to_list(recovery),
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
    ] ++
      if(@environment == :test,
        do: [
          test_helper: Map.get(config, :test_helper, false),
          on_transition: Map.get(config, :writer_hook)
        ],
        else: []
      )
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
      :insert_value_nodes
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
        is_boolean(c.start_paused) and
        Enum.all?([c.max_history_bytes, c.max_segments], fn limit ->
          limit == :infinity or (is_integer(limit) and limit >= 0)
        end) and
        c.client_bytes >= c.client_slots * 256 and
        c.rotation_target_bytes >= Tay.Storage.Segment.min_rotation_bytes() and
        c.rotation_target_bytes <= 1_073_741_824 and
        is_boolean(c.validated_filesystem) and c.durability in [:write, :sync] and
        (c.durability != :sync or (c.validated_filesystem and :os.type() == {:unix, :linux})) and
        (@environment != :prod or c.durability == :sync) and
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
end
