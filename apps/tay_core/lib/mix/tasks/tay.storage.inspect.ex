defmodule Mix.Tasks.Tay.Storage.Inspect do
  use Mix.Task
  @shortdoc "Inspect an existing locked Tay store physically and semantically, without activation"
  def run(arguments) do
    with {:ok, options} <- Tay.Diagnostics.cli_options(arguments, :inspect) do
      Mix.Task.run("compile")
      {:ok, _} = Application.ensure_all_started(:crypto)

      case Tay.Diagnostics.inspect(options) do
        {:ok, _} = result -> Mix.shell().info(Tay.Diagnostics.format(result))
        {:error, _} = result -> Mix.raise(Tay.Diagnostics.format(result))
      end
    else
      _ ->
        Mix.raise(
          "Use --data-dir PATH --durability sync|write [--validated-filesystem] and explicit resource budgets; no force, repair or mutation options exist"
        )
    end
  end
end
