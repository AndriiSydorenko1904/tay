defmodule Tay.ReleaseBench.Worker do
  use Tay.Worker, key: "tay.release-benchmark.v1", max_attempts: 1

  def perform(job) do
    elapsed = System.monotonic_time(:microsecond) - job.args["started_us"]
    Agent.update(Tay.ReleaseBench.Completed, &Map.put(&1, job.id, elapsed))
    :ok
  end
end

defmodule Tay.ReleaseBench do
  @name Tay.ReleaseBench.Engine
  @deadline_ms 120_000

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          path: :string,
          output: :string,
          jobs: :integer,
          clients: :integer,
          args_bytes: :integer,
          trials: :integer,
          mode: :string,
          validated_filesystem: :boolean
        ]
      )

    if rest != [] or invalid != [], do: raise("invalid release benchmark arguments")
    path = Keyword.fetch!(opts, :path)
    output = Keyword.fetch!(opts, :output)

    unless Path.type(path) == :absolute and not File.exists?(path),
      do: raise("benchmark requires a new absolute disposable directory")

    unless Path.type(output) == :absolute and not File.exists?(output),
      do: raise("report requires a new absolute path")

    jobs = Keyword.get(opts, :jobs, 1000)
    clients = Keyword.get(opts, :clients, 8)
    args_bytes = Keyword.get(opts, :args_bytes, 256)
    trials = Keyword.get(opts, :trials, 3)

    unless jobs in 1..100_000 and clients in 1..32 and args_bytes in 0..262_000 and
             trials in 1..10,
           do:
             raise(
               "benchmark bounds: jobs 1..100000, clients 1..32, args-bytes 0..262000, trials 1..10"
             )

    mode =
      case Keyword.get(opts, :mode, "write") do
        "write" -> :write
        "sync" -> :sync
        _ -> raise("mode must be write or sync")
      end

    validated = Keyword.get(opts, :validated_filesystem, false)

    if mode == :sync and not validated,
      do: raise("sync requires --validated-filesystem on a validated local volume")

    File.mkdir_p!(path)
    # Resolve the new parent because Tay correctly refuses symlink ancestors.
    {physical, 0} = System.cmd("pwd", ["-P"], cd: path)
    path = String.trim(physical)
    Application.put_env(:tay, :data_dir, path)
    {:ok, _} = Application.ensure_all_started(:tay)
    {:ok, completed} = Agent.start_link(fn -> %{} end, name: Tay.ReleaseBench.Completed)

    try do
      samples =
        for trial <- 1..trials do
          trial(Path.join(path, "store-#{trial}"), mode, validated, jobs, clients, args_bytes)
        end

      {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])

      report = %{
        report_schema: 1,
        benchmark: "tay-release-v1",
        measured_at_utc: DateTime.to_iso8601(DateTime.utc_now()),
        harness_sha256:
          Base.encode16(:crypto.hash(:sha256, File.read!(__ENV__.file)), case: :lower),
        working_tree_dirty: elem(System.cmd("git", ["status", "--porcelain"]), 0) != "",
        revision: String.trim(revision),
        version: to_string(Application.spec(:tay, :vsn)),
        workload: %{
          jobs: jobs,
          clients: clients,
          args_bytes: args_bytes,
          trials: trials,
          durability: mode
        },
        environment: %{
          os: inspect(:os.type()),
          architecture: to_string(:erlang.system_info(:system_architecture)),
          elixir: System.version(),
          otp: System.otp_release(),
          schedulers: :erlang.system_info(:schedulers_online),
          filesystem: filesystem(path)
        },
        measurements: samples,
        notes:
          "Synthetic public-API workload; throughput includes durable completion checks. Callback latency excludes durable finish. RSS sampled every 50ms, not a proven peak. Stores preserved. No production capacity or power-loss claim."
      }

      File.write!(output, Jason.encode!(report, pretty: true) <> "\n", [:exclusive])
    after
      Agent.stop(completed)
    end
  end

  defp trial(path, mode, validated, jobs, clients, args_bytes) do
    Agent.update(Tay.ReleaseBench.Completed, fn _ -> %{} end)
    storage = [data_dir: path, durability: mode, validated_filesystem: validated]
    {:ok, _} = Tay.Storage.initialize(storage)

    options =
      storage ++
        [
          name: @name,
          executor_socket: nil,
          http_port: nil,
          compaction: false,
          workers: %{"tay.release-benchmark.v1" => Tay.ReleaseBench.Worker},
          queues: [default: 4],
          caller_timeout: @deadline_ms,
          client_slots: 64
        ]

    {:ok, root} = Tay.start_link(options)
    Process.unlink(root)
    sampler = spawn_link(fn -> sample(%{rss: 0, beam: 0, count: 0}) end)
    started = System.monotonic_time(:microsecond)

    try do
      records =
        1..jobs
        |> Task.async_stream(
          fn _ ->
            before = System.monotonic_time(:microsecond)

            {:ok, job} =
              Tay.ReleaseBench.Worker.new(%{
                "started_us" => before,
                "payload" => String.duplicate("x", args_bytes)
              })

            {:ok, inserted} = Tay.insert(job, name: @name)
            {inserted.id, System.monotonic_time(:microsecond) - before}
          end,
          ordered: false,
          max_concurrency: clients,
          timeout: @deadline_ms
        )
        |> Enum.map(fn {:ok, value} -> value end)

      for {id, _} <- records,
          do: await_completed(id, System.monotonic_time(:millisecond) + @deadline_ms)

      elapsed = max(System.monotonic_time(:microsecond) - started, 1)
      callbacks = Agent.get(Tay.ReleaseBench.Completed, &Map.values/1)
      if length(callbacks) != jobs, do: raise("missing benchmark callback samples")
      compact_at = System.monotonic_time(:microsecond)
      {:ok, _} = Tay.compact(name: @name, timeout: @deadline_ms, terminal_retention: :infinity)
      compact_us = System.monotonic_time(:microsecond) - compact_at
      ref = make_ref()
      send(sampler, {:finish, self(), ref})

      memory =
        receive do
          {^ref, peak} -> peak
        after
          10_000 -> raise("memory sampler timeout")
        end

      %{
        completed_jobs_per_second: jobs * 1_000_000 / elapsed,
        enqueue_ack_p95_us: percentile(Enum.map(records, &elem(&1, 1)), 0.95),
        callback_latency_p95_us: percentile(callbacks, 0.95),
        compaction_us: compact_us,
        peak_rss_bytes: if(memory.rss > 0, do: memory.rss, else: nil),
        peak_beam_bytes: memory.beam,
        memory_samples: memory.count,
        jobs: jobs
      }
    after
      if Process.alive?(sampler), do: send(sampler, :stop)
      if Process.alive?(root), do: Supervisor.stop(root, :normal, :infinity)
    end
  end

  defp await_completed(id, deadline) do
    case Tay.get_job(id, name: @name) do
      {:ok, %{state: :completed}} ->
        :ok

      {:ok, %{state: state}} when state in [:available, :executing, :retryable] ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("job completion deadline")

        receive do
        after
          5 -> await_completed(id, deadline)
        end

      result ->
        raise("job completion failed: #{inspect(result, limit: 5)}")
    end
  end

  defp sample(peak) do
    rss =
      case System.cmd("ps", ["-o", "rss=", "-p", System.pid()]) do
        {text, 0} ->
          case Integer.parse(String.trim(text)) do
            {kb, _} -> kb * 1024
            _ -> 0
          end

        _ ->
          0
      end

    peak = %{
      rss: max(peak.rss, rss),
      beam: max(peak.beam, :erlang.memory(:total)),
      count: peak.count + 1
    }

    receive do
      {:finish, caller, ref} -> send(caller, {ref, peak})
      :stop -> :ok
    after
      50 -> sample(peak)
    end
  end

  defp percentile(values, fraction),
    do: Enum.at(Enum.sort(values), max(ceil(length(values) * fraction) - 1, 0))

  defp filesystem(path) do
    case :os.type() do
      {:unix, :linux} ->
        {text, 0} = System.cmd("stat", ["-f", "-c", "%T", path])
        String.trim(text)

      {:unix, :darwin} ->
        "macOS development filesystem"
    end
  end
end

Tay.ReleaseBench.run(System.argv())
