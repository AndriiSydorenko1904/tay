defmodule Mix.Tasks.Tay.Storage.Backup do
  use Mix.Task

  @moduledoc """
  Creates an exclusive cold backup of a stopped Tay store.

      mix tay.storage.backup --source /store --destination /backup --catalog /backup.json --durability development

  The default `--durability sync` requires `--validated-filesystem` and a
  supported persistent Linux filesystem. The destination and catalog must not
  exist; failed staging is retained for inspection.
  """

  @shortdoc "Creates an exclusive whole-store cold backup"

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:crypto)
    run_copy(arguments)
  end

  defp run_copy(arguments) do
    case Tay.Storage.ColdCopy.cli_options(arguments, :backup) do
      {:ok, result} -> Mix.shell().info(Tay.Storage.ColdCopy.format(result))
      {:error, error} -> Mix.raise(Tay.Storage.ColdCopy.format(error))
    end
  end
end
