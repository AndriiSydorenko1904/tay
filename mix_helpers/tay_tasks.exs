defmodule Mix.Tasks.Tay.Native do
  use Mix.Task

  @root Path.expand("..", __DIR__)

  @impl Mix.Task
  def run([]) do
    mix = System.find_executable("mix") || Mix.raise("cannot find the mix executable")

    {_, status} =
      System.cmd(mix, ["compile.tay_native", "--force"],
        cd: Path.join([@root, "apps", "tay"]),
        env: [{"MIX_ENV", Atom.to_string(Mix.env())}],
        into: IO.stream(:stdio, :line)
      )

    if status != 0, do: Mix.raise("Tay native helper compilation failed")
  end

  def run(_args), do: Mix.raise("usage: mix tay.native")
end

defmodule Tay.Umbrella.Hex do
  @moduledoc false

  @root Path.expand("..", __DIR__)

  def run!(app, args, published_dependencies? \\ false, extra_env \\ []) do
    Mix.shell().info("==> #{app}: mix #{Enum.join(args, " ")}")

    env =
      if published_dependencies?,
        do: [{"TAY_HEX_BUILD", "1"}],
        else: [{"TAY_HEX_BUILD", nil}]

    env = env ++ extra_env

    mix = System.find_executable("mix") || Mix.raise("cannot find the mix executable")

    {_, status} =
      System.cmd(mix, args,
        cd: Path.join([@root, "apps", app]),
        env: env,
        # Hex may request a two-factor code while publishing. Connecting the
        # subprocess directly to the terminal keeps that prompt interactive.
        use_stdio: false
      )

    if status != 0, do: Mix.raise("#{app}: mix #{Enum.join(args, " ")} failed")
  end
end

defmodule Mix.Tasks.Tay.Hex.Build do
  use Mix.Task

  @shortdoc "Builds all Tay Hex packages in dependency order"

  @impl Mix.Task
  def run([]) do
    Tay.Umbrella.Hex.run!("tay", ["hex.build"])
    Tay.Umbrella.Hex.run!("tay_http", ["hex.build"], true)
    Tay.Umbrella.Hex.run!("tay_dashboard", ["hex.build"], true)
  end

  def run(_args), do: Mix.raise("usage: mix tay.hex.build")
end

defmodule Mix.Tasks.Tay.Hex.Publish do
  use Mix.Task

  @shortdoc "Publishes all Tay Hex packages or their docs in dependency order"

  @impl Mix.Task
  def run([]), do: publish_all([])

  def run(["--dry-run"]), do: publish_all(["--dry-run"])

  def run(["docs"]) do
    for app <- ["tay", "tay_http", "tay_dashboard"] do
      Tay.Umbrella.Hex.run!(app, ["hex.publish", "docs", "--yes"])
    end
  end

  def run(_args), do: Mix.raise("usage: mix tay.hex.publish [docs | --dry-run]")

  defp publish_all(extra_args) do
    Tay.Umbrella.Hex.run!("tay", ["hex.publish", "--yes" | extra_args])
    publish_adapter("tay_http", extra_args)
    publish_adapter("tay_dashboard", extra_args)
  end

  defp publish_adapter(app, ["--dry-run"] = extra_args) do
    Tay.Umbrella.Hex.run!(app, ["hex.build"], true)
    Tay.Umbrella.Hex.run!(app, ["hex.publish", "docs", "--yes" | extra_args])
  end

  defp publish_adapter(app, []) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "tay-hex-#{app}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(workspace)

    env = [
      {"MIX_ENV", "prod"},
      {"TAY_HEX_WORKSPACE", workspace}
    ]

    try do
      Tay.Umbrella.Hex.run!(app, ["deps.get", "--only", "prod"], true, env)
      Tay.Umbrella.Hex.run!(app, ["hex.publish", "package", "--yes"], true, env)
    after
      File.rm_rf!(workspace)
    end

    Tay.Umbrella.Hex.run!(app, ["hex.publish", "docs", "--yes"])
  end
end
