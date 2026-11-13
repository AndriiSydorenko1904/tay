defmodule Tay.UpgradeDrill.Worker do
  use Tay.Worker, key: "tay.upgrade.completed.v1"
  def perform(_job), do: :ok
end

defmodule Tay.UpgradeDrill do
  def run(arguments) do
    {opts, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [action: :string, path: :string, mode: :string, validated_filesystem: :boolean]
      )

    if rest != [] or invalid != [], do: raise("invalid upgrade drill arguments")
    action = Keyword.fetch!(opts, :action)
    unless action in ["seed", "verify"], do: raise("action must be seed or verify")
    path = Keyword.fetch!(opts, :path)
    unless Path.type(path) == :absolute, do: raise("path must be absolute")

    mode =
      case Keyword.get(opts, :mode, "write") do
        "write" -> :write
        "sync" -> :sync
        _ -> raise("mode must be write or sync")
      end

    storage = [
      data_dir: path,
      durability: mode,
      validated_filesystem: Keyword.get(opts, :validated_filesystem, false)
    ]

    Application.put_env(:tay, :data_dir, path)
    {:ok, _} = Application.ensure_all_started(:tay)

    if action == "seed" do
      if File.exists?(path), do: raise("seed requires a new disposable store")
      {:ok, _} = Tay.Storage.initialize(storage)
    end

    options =
      if(
        Mix.env() == :prod and Version.match?(to_string(Application.spec(:tay, :vsn)), ">= 2.0.0"),
        do: Keyword.delete(storage, :durability),
        else: storage
      ) ++
        [
          executor_socket: nil,
          http_port: nil,
          compaction: false,
          queues: [default: 2],
          workers: %{"tay.upgrade.completed.v1" => Tay.UpgradeDrill.Worker}
        ]

    {:ok, root} = Tay.start_link(options)
    Process.unlink(root)

    try do
      if action == "seed", do: seed(), else: verify()

      IO.puts(
        Jason.encode!(%{
          action: action,
          version: to_string(Application.spec(:tay, :vsn)),
          path: path,
          durability: mode,
          result: "passed"
        })
      )
    after
      Supervisor.stop(root)
    end
  end

  defp seed do
    {:ok, completed} =
      Tay.UpgradeDrill.Worker.new(%{"upgrade" => "completed"}, id: String.duplicate("1", 32))

    {:ok, _} = Tay.insert(completed)

    {:ok, pending} =
      Tay.UpgradeDrill.Worker.new(%{"upgrade" => "pending"},
        scheduled_at: System.system_time(:millisecond) + 3_600_000,
        id: String.duplicate("2", 32)
      )

    {:ok, _} = Tay.insert(pending)

    {:ok, schedule} =
      Tay.Schedule.new(
        "upgrade-hourly",
        %{
          "task" => "tay.upgrade.completed.v1",
          "args" => %{"upgrade" => "schedule"},
          "every" => %{"hours" => 1},
          "options" => %{"queue" => "default"}
        },
        System.system_time(:millisecond)
      )

    {:ok, _} = Tay.register_schedule(schedule)
    await_completed(System.monotonic_time(:millisecond) + 30_000)
  end

  defp verify do
    {:ok, %{state: :completed, args: %{"upgrade" => "completed"}}} =
      Tay.get_job(String.duplicate("1", 32))

    {:ok, %{state: :scheduled, args: %{"upgrade" => "pending"}}} =
      Tay.get_job(String.duplicate("2", 32))

    {:ok, [schedule]} = Tay.schedules()
    "upgrade-hourly" = schedule.id
    nil = schedule.cancelled_at
    {:ok, _} = Tay.compact(timeout: 120_000, terminal_retention: :infinity)
    {:ok, _} = Tay.cancel_schedule(schedule.id)
    :ok = Tay.restart(timeout: 120_000)
    {:ok, [recovered]} = Tay.schedules()
    true = is_integer(recovered.cancelled_at)
    {:ok, %{state: :completed}} = Tay.get_job(String.duplicate("1", 32))
    {:ok, %{state: :scheduled}} = Tay.get_job(String.duplicate("2", 32))
  end

  defp await_completed(deadline) do
    case Tay.get_job(String.duplicate("1", 32)) do
      {:ok, %{state: :completed}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("completion deadline")
        Process.sleep(10)
        await_completed(deadline)
    end
  end
end

Tay.UpgradeDrill.run(System.argv())
