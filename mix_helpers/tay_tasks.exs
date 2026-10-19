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

  def run!(app, args, published_dependencies? \\ false) do
    Mix.shell().info("==> #{app}: mix #{Enum.join(args, " ")}")

    env =
      if published_dependencies?,
        do: [{"TAY_HEX_BUILD", "1"}],
        else: [{"TAY_HEX_BUILD", nil}]

    mix = System.find_executable("mix") || Mix.raise("cannot find the mix executable")

    {_, status} =
      System.cmd(mix, args,
        cd: Path.join([@root, "apps", app]),
        env: env,
        into: IO.stream(:stdio, :line)
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
  def run([]) do
    Tay.Umbrella.Hex.run!("tay", ["hex.publish", "--yes"])
    publish_adapter("tay_http")
    publish_adapter("tay_dashboard")
  end

  def run(["docs"]) do
    for app <- ["tay", "tay_http", "tay_dashboard"] do
      Tay.Umbrella.Hex.run!(app, ["hex.publish", "docs", "--yes"])
    end
  end

  def run(_args), do: Mix.raise("usage: mix tay.hex.publish [docs]")

  defp publish_adapter(app) do
    Tay.Umbrella.Hex.run!(app, ["hex.publish", "package", "--yes"], true)
    Tay.Umbrella.Hex.run!(app, ["hex.publish", "docs", "--yes"])
  end
end
