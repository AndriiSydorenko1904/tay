defmodule Mix.Tasks.Tay.Storage.Inspect do
  use Mix.Task
  @shortdoc "Inspect an existing locked Tay store physically and semantically, without activation"
  @moduledoc """
  Inspects the complete retained history of an existing store without activation.

      mix tay.storage.inspect --data-dir PATH --durability sync --validated-filesystem

  Options:

    * `--data-dir PATH` — existing storage root (required)
    * `--durability sync|write` — inspection mode, defaults to `sync`
    * `--validated-filesystem` — required for strict `sync` mode
    * `--max-state-bytes N` — retained state-memory budget
    * `--deadline-ms N` — inspection time budget

  Inspection never repairs, truncates or skips records.
  """
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
          "Use --data-dir PATH --durability sync|write [--validated-filesystem] [--max-state-bytes N] [--deadline-ms N]; no force, repair or mutation options exist"
        )
    end
  end
end
