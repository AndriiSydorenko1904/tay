defmodule Tay.Diagnostics do
  @moduledoc """
  Locked, existing-only offline physical and Event replay diagnostics.

  No activation, writer capability, job data or partial candidate is returned.
  Successful inspection is not authorization to mutate or a backup certificate.
  Resource limits are operational budgets and never alter physical validity.
  """
  alias Tay.Storage.{Native, Recovery}
  alias Tay.Storage.Recovery.Error
  alias Tay.State.Transition
  @states [:available, :scheduled, :executing, :retryable, :completed, :discarded, :cancelled]

  def inspect(options) do
    with {:ok, config} <- options(options) do
      isolated(
        fn -> inspect_store(config) end,
        config.recovery.deadline_ms + config.recovery.io_timeout_ms + 1_000,
        failure(:inspection_failed)
      )
    end
  end

  @doc false
  def initialize(options) do
    failed =
      {:error,
       %{
         state: :unconfirmed,
         kind: :initialization_failed,
         mutation: :unknown,
         action: :preserve_and_stop
       }}

    isolated(
      fn ->
        case Tay.Storage.initialize(options) do
          {:ok, result} -> {:ok, Map.take(result, [:durability, :segment_id])}
          _ -> failed
        end
      end,
      180_000,
      failed
    )
  end

  defp isolated(operation, timeout, failed) do
    owner = self()
    ticket = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        target = self()
        spawn(fn -> watch_owner(owner, target) end)

        result =
          try do
            operation.()
          catch
            _, _ -> failed
          end

        send(owner, {ticket, result})
      end)

    await_isolated(worker, monitor, ticket, System.monotonic_time(:millisecond) + timeout, failed)
  end

  # Recovery deadlines are operational positive integers, not a 32-bit format
  # field. A BEAM receive timer has a narrower bound: keep the absolute deadline
  # intact and split only the local wait, rather than rejecting/shortening it.
  defp await_isolated(worker, monitor, ticket, deadline, failed) do
    wait = min(max(deadline - System.monotonic_time(:millisecond), 0), 4_294_967_295)

    receive do
      {^ticket, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _} ->
        failed
    after
      wait ->
        if System.monotonic_time(:millisecond) >= deadline do
          Process.exit(worker, :kill)
          Process.demonitor(monitor, [:flush])
          failed
        else
          await_isolated(worker, monitor, ticket, deadline, failed)
        end
    end
  end

  defp watch_owner(owner, worker) do
    caller = Process.monitor(owner)
    child = Process.monitor(worker)

    receive do
      {:DOWN, ^caller, :process, _, _} -> Process.exit(worker, :kill)
      {:DOWN, ^child, :process, _, _} -> :ok
    end
  end

  defp inspect_store(config) do
    native_options = [
      durability: config.durability,
      validated_filesystem: config.validated_filesystem,
      timeout: config.recovery.io_timeout_ms,
      max_directory_entries: config.recovery.max_directory_entries,
      deadline: System.monotonic_time(:millisecond) + config.recovery.deadline_ms
    ]

    case Native.open_existing(config.data_dir, native_options) do
      {:ok, native} ->
        try do
          candidate = Transition.candidate(config.candidate, config.recovery.event_limits)

          case Recovery.replay(
                 native,
                 Tay.Event,
                 candidate,
                 &Transition.reduce/3,
                 Map.to_list(config.recovery)
               ) do
            {:ok, summary, candidate} ->
              counts =
                Enum.reduce(candidate.jobs, Map.new(@states, &{&1, 0}), fn {_, job}, acc ->
                  Map.update!(acc, job.state, &(&1 + 1))
                end)

              {:ok,
               %{
                 state: :valid,
                 scope: :physical_and_semantic,
                 mutation: :none,
                 activation: :not_attempted,
                 store_id: Base.encode16(summary.store_id, case: :lower),
                 record_count: summary.record_count,
                 segment_count: summary.segment_count,
                 total_segment_bytes: summary.total_segment_bytes,
                 next_sequence: summary.next_sequence,
                 staging_count: summary.staging_count,
                 ignored_count: summary.ignored_count,
                 jobs: map_size(candidate.jobs),
                 states: counts,
                 state_bytes_charged: candidate.bytes,
                 state_nodes_charged: candidate.nodes
               }}

            {:error, error} ->
              diagnostic(error)
          end
        after
          Native.shutdown(native)
        end

      {:error, error} ->
        diagnostic(Error.wrap(error, :ownership))
    end
  end

  defp options(input) do
    allowed = [
      :data_dir,
      :durability,
      :validated_filesystem,
      :recovery,
      :max_jobs,
      :max_state_bytes,
      :max_state_nodes
    ]

    with true <- Tay.Engine.Config.keyword?(input, allowed),
         {:ok, foundation} <- Tay.Config.new(data_dir: Keyword.get(input, :data_dir)),
         true <- is_binary(foundation.data_dir),
         mode = Keyword.get(input, :durability, :sync),
         true <- mode in [:write, :sync],
         validated = Keyword.get(input, :validated_filesystem, false),
         true <- is_boolean(validated),
         {:ok, recovery} <- Recovery.options(Keyword.get(input, :recovery, [])),
         candidate = %{
           max_jobs: Keyword.get(input, :max_jobs, 100_000),
           max_bytes: Keyword.get(input, :max_state_bytes, 268_435_456),
           max_nodes: Keyword.get(input, :max_state_nodes, 2_000_000)
         },
         true <- Enum.all?(candidate, fn {_, n} -> is_integer(n) and n >= 0 end) do
      {:ok,
       %{
         data_dir: foundation.data_dir,
         durability: mode,
         validated_filesystem: validated,
         recovery: recovery,
         candidate: candidate
       }}
    else
      _ -> failure(:invalid_options)
    end
  end

  defp diagnostic(%Error{} = error) do
    {:error,
     %{
       state: :refused,
       kind: error.kind,
       stage: error.stage,
       segment_id: error.segment_id,
       offset: error.offset,
       sequence: error.sequence,
       reason: reason(error.reason),
       action: :preserve_and_stop,
       mutation: :none
     }}
  end

  defp reason(value) when is_atom(value), do: value
  defp reason({key, value}) when is_atom(key) and is_integer(value), do: {key, value}
  defp reason({:resource_limit, key}) when is_atom(key), do: {:resource_limit, key}
  defp reason(_), do: :details_redacted

  defp failure(kind),
    do: {:error, %{state: :refused, kind: kind, action: :preserve_and_stop, mutation: :none}}

  @doc false
  def format(result), do: Kernel.inspect(result, pretty: false, limit: 60, printable_limit: 128)

  @doc false
  def cli_options(arguments, operation) when operation in [:init, :inspect] do
    switches = [data_dir: :string, durability: :string, validated_filesystem: :boolean]

    switches =
      switches ++
        if(operation == :init,
          do: [bootstrap_existing: :boolean],
          else: [
            max_jobs: :integer,
            max_state_bytes: :integer,
            max_state_nodes: :integer,
            max_records: :integer,
            max_bytes: :integer,
            deadline_ms: :integer
          ]
        )

    {options, remaining, invalid} = OptionParser.parse(arguments, strict: switches)
    mode = Keyword.get(options, :durability, "sync")

    if remaining == [] and invalid == [] and is_binary(options[:data_dir]) and
         length(options) == length(Enum.uniq(Keyword.keys(options))) and mode in ["write", "sync"] do
      base = [
        data_dir: options[:data_dir],
        durability: if(mode == "sync", do: :sync, else: :write),
        validated_filesystem: Keyword.get(options, :validated_filesystem, false)
      ]

      if operation == :init do
        {:ok, base ++ [bootstrap: Keyword.get(options, :bootstrap_existing, false)]}
      else
        recovery =
          for {from, to} <- [
                max_records: :max_replay_records,
                max_bytes: :max_total_segment_bytes,
                deadline_ms: :deadline_ms
              ],
              Keyword.has_key?(options, from),
              do: {to, options[from]}

        {:ok,
         base ++
           Keyword.take(options, [:max_jobs, :max_state_bytes, :max_state_nodes]) ++
           [recovery: recovery]}
      end
    else
      failure(:invalid_options)
    end
  end
end
