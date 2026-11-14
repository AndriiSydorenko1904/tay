defmodule Tay.CompactionBench.Worker do
  use Tay.Worker, key: "tay.compaction-fixture.v1", max_attempts: 1
  def perform(_job), do: :ok
end

defmodule Tay.CompactionBench do
  alias Tay.Storage.ColdCopy
  @name Tay.CompactionBench.Engine
  @profiles ~w(bootstrap checkpoint mixed)
  @terminal ~w(completed cancelled discarded)
  @harness_sha256 Base.encode16(:crypto.hash(:sha256, File.read!(__ENV__.file)), case: :lower)

  def run(arguments) do
    {opts, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [
          action: :string,
          fixture: :string,
          path: :string,
          output: :string,
          profile: :string,
          jobs: :integer,
          args_bytes: :integer,
          clients: :integer,
          delta_jobs: :integer,
          expire_terminal: :boolean,
          timeout_ms: :integer,
          mode: :string,
          validated_filesystem: :boolean
        ]
      )

    if rest != [] or invalid != [] or length(opts) != length(Enum.uniq(Keyword.keys(opts))),
      do: raise("invalid compaction benchmark arguments")

    action = Keyword.fetch!(opts, :action)
    unless action in ["seed", "run"], do: raise("action must be seed or run")
    mode = Keyword.get(opts, :mode, "write")
    unless mode in ["write", "sync"], do: raise("mode must be write or sync")
    mode = if mode == "sync", do: :sync, else: :write
    validated = Keyword.get(opts, :validated_filesystem, false)
    if mode == :sync and not validated, do: raise("sync requires --validated-filesystem")
    if Mix.env() == :prod and mode != :sync, do: raise("production builds require sync")
    timeout = bounded!(opts, :timeout_ms, 120_000, 1..900_000)

    data_dir =
      if action == "seed",
        do: Path.join(Keyword.fetch!(opts, :fixture), "seed-store"),
        else: Path.join(Keyword.fetch!(opts, :path), "store")

    Application.put_env(:tay, :data_dir, data_dir)
    {:ok, _} = Application.ensure_all_started(:tay)

    if action == "seed",
      do: seed(opts, mode, validated, timeout),
      else: measure(opts, mode, validated, timeout)
  end

  defp seed(opts, mode, validated, timeout) do
    if Enum.any?([:path, :output, :delta_jobs, :expire_terminal], &Keyword.has_key?(opts, &1)),
      do: raise("path, output, delta-jobs and expire-terminal are run options")

    profile = Keyword.get(opts, :profile, "bootstrap")
    unless profile in @profiles, do: raise("profile must be bootstrap, checkpoint or mixed")
    jobs = bounded!(opts, :jobs, 10_000, 1..100_000)
    bytes = bounded!(opts, :args_bytes, 256, 0..262_000)
    clients = bounded!(opts, :clients, 8, 1..32)
    fixture = new_path!(Keyword.fetch!(opts, :fixture))
    File.mkdir!(fixture)
    source = Path.join(fixture, "seed-store")
    {:ok, _} = Tay.Storage.initialize(storage(source, mode, validated))

    manifest =
      with_engine(source, mode, validated, timeout, fn ->
        {counts, samples} =
          1..jobs
          |> Task.async_stream(
            &insert_fixture_job(&1, jobs, profile, bytes, timeout),
            max_concurrency: clients,
            ordered: false,
            timeout: timeout
          )
          |> Enum.reduce({%{}, []}, fn {:ok, {state, sample}}, {counts, samples} ->
            {Map.update(counts, state, 1, &(&1 + 1)),
             if(sample, do: [sample | samples], else: samples)}
          end)

        await_count(jobs, timeout)
        if profile == "checkpoint", do: compact!(false, timeout)

        %{
          "schema" => 1,
          "fixture" => "tay-compaction-v1",
          "profile" => profile,
          "jobs" => jobs,
          "args_bytes" => bytes,
          "counts" => counts,
          "samples" => Enum.sort_by(samples, & &1["id"]),
          "seed_version" => to_string(Application.spec(:tay, :vsn)),
          "seed_revision" => revision(),
          "seed_working_tree_dirty" => dirty?(),
          "seed_harness_sha256" => @harness_sha256,
          "seed_durability" => Atom.to_string(mode)
        }
      end)

    {:ok, _} =
      ColdCopy.backup(
        copy_options(
          source,
          Path.join(fixture, "store"),
          Path.join(fixture, "catalog.json"),
          mode,
          validated
        )
      )

    manifest = Map.put(manifest, "catalog_sha256", file_hash(Path.join(fixture, "catalog.json")))
    write_json!(Path.join(fixture, "fixture.json"), manifest)
    IO.puts("Compaction fixture ready: #{fixture}")
  end

  defp insert_fixture_job(index, jobs, profile, bytes, timeout) do
    pending = profile == "mixed" and rem(index, 10) in [0, 1]
    options = if pending, do: [scheduled_at: Tay.Event.V2.max_time()], else: []

    {:ok, intent} =
      Tay.CompactionBench.Worker.new(%{"payload" => String.duplicate("x", bytes)}, options)

    {:ok, inserted} = Tay.insert(intent, name: @name)

    state =
      cond do
        pending and rem(index, 10) == 1 ->
          {:ok, _} = Tay.cancel(inserted.id, name: @name, expected_revision: inserted.revision)
          "cancelled"

        pending ->
          "scheduled"

        true ->
          await_completed(inserted.id, timeout)
          "completed"
      end

    sample = if index <= 10 or index == jobs, do: sample(intent, state)
    {state, sample}
  end

  defp measure(opts, mode, validated, timeout) do
    if Enum.any?([:profile, :jobs, :args_bytes, :clients], &Keyword.has_key?(opts, &1)),
      do: raise("profile, jobs, args-bytes and clients are seed options")

    fixture = existing_directory!(Keyword.fetch!(opts, :fixture))
    manifest_path = Path.join(fixture, "fixture.json")
    manifest_bytes = File.read!(manifest_path)
    fixture_hash = hash(manifest_bytes)
    manifest = Jason.decode!(manifest_bytes)

    unless manifest["schema"] == 1 and manifest["fixture"] == "tay-compaction-v1" and
             manifest["profile"] in @profiles and manifest["jobs"] in 1..100_000,
           do: raise("invalid compaction fixture manifest")

    unless file_hash(Path.join(fixture, "catalog.json")) == manifest["catalog_sha256"],
      do: raise("fixture catalog checksum mismatch")

    path = new_path!(Keyword.fetch!(opts, :path))
    output = new_path!(Keyword.fetch!(opts, :output))

    if path == output or inside?(path, fixture) or inside?(output, fixture),
      do: raise("run paths must be distinct and outside the immutable fixture")

    delta = bounded!(opts, :delta_jobs, 0, 0..1_000)
    expire = Keyword.get(opts, :expire_terminal, false)
    File.mkdir!(path)
    target = Path.join(path, "store")

    {restore_us, {:ok, _}} =
      :timer.tc(fn ->
        ColdCopy.restore(
          copy_options(
            Path.join(fixture, "store"),
            target,
            Path.join(path, "restore.json"),
            mode,
            validated
          ) ++
            [verify_catalog: Path.join(fixture, "catalog.json")]
        )
      end)

    startup_at = System.monotonic_time(:microsecond)

    {measurement, samples} =
      with_engine(target, mode, validated, timeout, fn ->
        startup_us = System.monotonic_time(:microsecond) - startup_at
        verify_samples!(manifest["samples"], false)
        await_count(manifest["jobs"], timeout)

        {delta_us, delta_samples} =
          :timer.tc(fn ->
            for index <- indices(delta) do
              {:ok, job} = Tay.CompactionBench.Worker.new(%{"delta" => index})
              {:ok, _} = Tay.insert(job, name: @name)
              await_completed(job.id, timeout)
              sample(job, "completed")
            end
          end)

        total = manifest["jobs"] + delta
        await_count(total, timeout)
        :erlang.garbage_collect()
        {compact_us, stats, memory} = measured_compaction(expire, timeout)
        terminals = Enum.reduce(@terminal, delta, &(&2 + Map.get(manifest["counts"], &1, 0)))
        expected = if expire, do: total - terminals, else: total
        await_count(expected, timeout)
        verify_samples!(manifest["samples"] ++ delta_samples, expire)
        true = stats.expired_jobs == if(expire, do: terminals, else: 0)

        measurement = %{
          restore_us: restore_us,
          startup_us: startup_us,
          delta_us: delta_us,
          compaction_us: compact_us,
          memory: memory,
          jobs_before: total,
          jobs_after: expected,
          stats:
            Map.take(stats, [
              :expired_jobs,
              :retained_terminal_jobs,
              :reused_bytes,
              :rewritten_bytes,
              :reclaimed_bytes,
              :pause_ms,
              :total_ms
            ]),
          verification: "counts, sampled definitions/states, and restart passed"
        }

        {measurement, manifest["samples"] ++ delta_samples}
      end)

    with_engine(target, mode, validated, timeout, fn ->
      await_count(measurement.jobs_after, timeout)
      verify_samples!(samples, expire)
    end)

    unless file_hash(manifest_path) == fixture_hash and
             file_hash(Path.join(fixture, "catalog.json")) == manifest["catalog_sha256"],
           do: raise("fixture metadata changed during the run")

    write_json!(output, %{
      report_schema: 1,
      benchmark: "tay-compaction-fixture-v1",
      fixture_sha256: fixture_hash,
      catalog_sha256: manifest["catalog_sha256"],
      fixture: Map.drop(manifest, ["samples"]),
      revision: revision(),
      working_tree_dirty: dirty?(),
      version: to_string(Application.spec(:tay, :vsn)),
      measured_at_utc: DateTime.to_iso8601(DateTime.utc_now()),
      harness_sha256: @harness_sha256,
      durability: mode,
      delta_jobs: delta,
      expire_terminal: expire,
      timeout_ms: timeout,
      schedulers: :erlang.system_info(:schedulers_online),
      os: inspect(:os.type()),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      logical_processors: :erlang.system_info(:logical_processors_available),
      filesystem: filesystem(target),
      elixir: System.version(),
      otp: System.otp_release(),
      measurement: measurement,
      memory_scope: "compaction only, RSS sampled every 250 ms, BEAM every 25 ms",
      copy_method: "catalog-verified ColdCopy.restore, ordinary native reads/writes"
    })
  end

  defp with_engine(path, mode, validated, timeout, fun) do
    options = storage(path, mode, validated)
    options = if Mix.env() == :prod, do: Keyword.delete(options, :durability), else: options

    {:ok, root} =
      Tay.start_link(
        options ++
          [
            name: @name,
            executor_socket: nil,
            http_port: nil,
            compaction: false,
            workers: %{"tay.compaction-fixture.v1" => Tay.CompactionBench.Worker},
            queues: [default: 4],
            client_slots: 64,
            caller_timeout: timeout
          ]
      )

    Process.unlink(root)

    try do
      fun.()
    after
      if Process.alive?(root), do: Supervisor.stop(root, :normal, :infinity)
    end
  end

  defp compact!(expire, timeout) do
    {:ok, stats} =
      Tay.compact(
        name: @name,
        timeout: timeout,
        terminal_retention: if(expire, do: {:hours, 0}, else: :infinity)
      )

    stats
  end

  defp sample(job, state),
    do: %{"id" => job.id, "state" => state, "definition_sha256" => definition_hash(job)}

  defp definition_hash(job) do
    {:ok, bytes} = Tay.Event.Value.encode(job.definition)
    hash(bytes)
  end

  defp verify_samples!(samples, expire) do
    for sample <- samples do
      if expire and sample["state"] in @terminal do
        {:error, :not_found} = Tay.get_job(sample["id"], name: @name)
      else
        {:ok, job} = Tay.get_job(sample["id"], name: @name)
        true = Atom.to_string(job.state) == sample["state"]
        true = definition_hash(job) == sample["definition_sha256"]
      end
    end
  end

  defp await_completed(id, timeout) do
    await(
      fn ->
        case Tay.get_job(id, name: @name) do
          {:ok, %{state: :completed}} -> true
          {:ok, %{state: state}} when state in [:available, :executing, :retryable] -> false
          other -> raise("fixture completion failed: #{inspect(other)}")
        end
      end,
      System.monotonic_time(:millisecond) + timeout
    )
  end

  defp await_count(count, timeout),
    do:
      await(
        fn -> Tay.status(name: @name)[:jobs] == count end,
        System.monotonic_time(:millisecond) + timeout
      )

  defp await(fun, deadline) do
    unless fun.() do
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("fixture verification timeout")

      Process.sleep(5)
      await(fun, deadline)
    end
  end

  defp measured_compaction(expire, timeout) do
    caller = self()
    reference = make_ref()

    sampler =
      spawn_link(fn ->
        peak = observe(%{rss: 0, beam: 0, count: 0, rss_at: nil})
        send(caller, {:sample_ready, reference})
        sample_loop(peak, caller, reference)
      end)

    receive do: ({:sample_ready, ^reference} -> :ok)

    try do
      {elapsed, stats} = :timer.tc(fn -> compact!(expire, timeout) end)
      send(sampler, :finish)

      receive do
        {:sample_finished, ^reference, peak} -> {elapsed, stats, Map.delete(peak, :rss_at)}
      after
        10_000 -> raise("compaction sampler timeout")
      end
    after
      if Process.alive?(sampler), do: send(sampler, :stop)
    end
  end

  defp sample_loop(peak, caller, reference) do
    receive do
      :finish -> send(caller, {:sample_finished, reference, observe(peak)})
      :stop -> :ok
    after
      25 -> sample_loop(observe(peak), caller, reference)
    end
  end

  defp observe(peak) do
    now = System.monotonic_time(:millisecond)

    peak =
      if is_nil(peak.rss_at) or now - peak.rss_at >= 250 do
        {text, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
        %{peak | rss: max(peak.rss, String.to_integer(String.trim(text)) * 1024), rss_at: now}
      else
        peak
      end

    %{peak | beam: max(peak.beam, :erlang.memory(:total)), count: peak.count + 1}
  end

  defp storage(path, mode, validated),
    do: [data_dir: path, durability: mode, validated_filesystem: validated]

  defp copy_options(source, target, catalog, mode, validated),
    do: [
      source: source,
      destination: target,
      catalog: catalog,
      durability: if(mode == :sync, do: :sync, else: :development),
      validated_filesystem: validated
    ]

  defp indices(0), do: []
  defp indices(n), do: 1..n

  defp filesystem(path) do
    case :os.type() do
      {:unix, :linux} ->
        {name, 0} = System.cmd("stat", ["-f", "-c", "%T", path])
        String.trim(name)

      {:unix, :darwin} ->
        "macOS development filesystem"
    end
  end

  defp revision,
    do: System.cmd("git", ["rev-parse", "HEAD"]) |> then(fn {value, 0} -> String.trim(value) end)

  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp dirty?, do: elem(System.cmd("git", ["status", "--porcelain"]), 0) != ""
  defp file_hash(path), do: path |> File.read!() |> hash()

  defp write_json!(path, value),
    do: File.write!(path, Jason.encode!(value, pretty: true) <> "\n", [:exclusive])

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp bounded!(opts, key, default, range) do
    value = Keyword.get(opts, key, default)
    unless is_integer(value) and value in range, do: raise("invalid #{key}")
    value
  end

  defp existing_directory!(path) do
    unless Path.type(path) == :absolute, do: raise("fixture must be absolute")
    {physical, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(physical)
  end

  defp new_path!(path) do
    unless Path.type(path) == :absolute, do: raise("output paths must be absolute")
    parent = existing_directory!(Path.dirname(path))
    resolved = Path.join(parent, Path.basename(path))
    unless File.lstat(resolved) == {:error, :enoent}, do: raise("output path already exists")
    resolved
  end
end

Tay.CompactionBench.run(System.argv())
