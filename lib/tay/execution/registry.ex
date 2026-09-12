defmodule Tay.Execution.Registry do
  @moduledoc """
  Resolves an inert persisted worker key through the trusted runtime map only.
  Resolution never converts text to atoms, loads code, or participates in replay.
  A missing mapping or currently unloaded callback blocks dispatch, not history.
  """
  alias Tay.Event.V1

  def resolve(registry, worker_key) when is_map(registry) do
    if V1.key?(worker_key) do
      case Map.get(registry, worker_key) do
        module when is_atom(module) and module not in [nil, false, true] ->
          if function_exported?(module, :perform, 1),
            do: {:ok, module},
            else: {:error, :unavailable_worker}

        _ ->
          {:error, :unavailable_worker}
      end
    else
      {:error, :unavailable_worker}
    end
  end

  def resolve(_, _), do: {:error, :unavailable_worker}
end
