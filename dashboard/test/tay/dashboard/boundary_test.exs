defmodule Tay.Dashboard.BoundaryTest do
  use ExUnit.Case, async: true

  test "dashboard source references only Tay public API" do
    source =
      Path.expand("../../../lib", __DIR__)
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    for forbidden <- ["Tay.Engine", "Tay.State", "Tay.Storage", ":ets.", "GenServer"] do
      refute source =~ forbidden
    end
  end
end
