defmodule Mix.Tasks.Tay.Storage.Restore do
  use Mix.Task

  @moduledoc """
  Restores a cold backup after verifying its external SHA-256 catalog.

      mix tay.storage.restore --source /backup --destination /store --catalog /restore.json --verify-catalog /backup.json --durability development

  The default `--durability sync` requires `--validated-filesystem` and a
  supported persistent Linux filesystem. The destination and new catalog
  must not exist; failed staging is retained for inspection.
  """

  @shortdoc "Restores an exclusive whole-store cold backup"

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:crypto)
    run_copy(arguments)
  end

  defp run_copy(arguments) do
    case Tay.Storage.ColdCopy.cli_options(arguments, :restore) do
      {:ok, result} -> Mix.shell().info(Tay.Storage.ColdCopy.format(result))
      {:error, error} -> Mix.raise(Tay.Storage.ColdCopy.format(error))
    end
  end
end
