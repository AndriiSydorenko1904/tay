defmodule Tay.Execution.RegistryTest do
  use ExUnit.Case, async: true
  alias Tay.Execution.Registry

  defmodule Worker do
    @behaviour Tay.Worker
    @impl true
    def perform(_), do: raise("resolution cannot execute worker code")
  end

  test "only an explicit trusted mapping to a loaded perform/1 callback resolves" do
    assert {:ok, Worker} = Registry.resolve(%{"stable/worker" => Worker}, "stable/worker")

    for registry <- [
          %{},
          %{"stable/worker" => Enum},
          %{"stable/worker" => nil},
          %{"stable/worker" => true},
          %{"stable/worker" => "Elixir.Arbitrary"}
        ] do
      assert {:error, :unavailable_worker} = Registry.resolve(registry, "stable/worker")
    end

    assert {:error, :unavailable_worker} = Registry.resolve(nil, "stable/worker")
    assert {:error, :unavailable_worker} = Registry.resolve(%{"" => Worker}, "")
    assert {:error, :unavailable_worker} = Registry.resolve(%{}, <<255>>)
  end

  test "persisted text never loads a module or creates atoms; trusted remapping preserves key" do
    # This module atom exists in the source but has no loaded code. Resolving its
    # explicit mapping must not attempt ensure_loaded or infer a module from key.
    unloaded = Tay.Execution.RegistryTest.DeliberatelyUnloadedWorker
    assert :code.is_loaded(unloaded) == false
    assert {:error, :unavailable_worker} = Registry.resolve(%{"key" => unloaded}, "key")
    assert :code.is_loaded(unloaded) == false
    key = "untrusted.module." <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert {:error, :unavailable_worker} = Registry.resolve(%{}, key)
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert {:ok, Worker} = Registry.resolve(%{key => Worker}, key)
  end
end
