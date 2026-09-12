defmodule Mix.Tasks.Tay.Storage.Init do
  use Mix.Task
  @shortdoc "Explicitly initialize a new Tay store; never repair or open existing history"
  def run(arguments) do
    with {:ok, options} <- Tay.Diagnostics.cli_options(arguments, :init) do
      Mix.Task.run("compile")
      {:ok, _} = Application.ensure_all_started(:crypto)

      case Tay.Diagnostics.initialize(options) do
        {:ok, result} ->
          Mix.shell().info(
            Tay.Diagnostics.format({:ok, Map.take(result, [:durability, :segment_id])})
          )

        {:error, _} ->
          Mix.raise(
            "Tay initialization did not establish success; preserve the existing path and inspect it separately"
          )
      end
    else
      _ ->
        Mix.raise(
          "Use --data-dir PATH --durability sync|write [--validated-filesystem] [--bootstrap-existing]; no force or repair options exist"
        )
    end
  end
end
