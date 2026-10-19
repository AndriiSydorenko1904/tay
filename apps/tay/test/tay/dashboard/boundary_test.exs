defmodule Tay.Dashboard.BoundaryTest do
  use ExUnit.Case, async: true

  test "dashboard source references only Tay public API" do
    source =
      Path.expand("../../../lib/tay/dashboard", __DIR__)
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    for forbidden <- ["Tay.Engine", "Tay.State", "Tay.Storage", ":ets.", "GenServer"] do
      refute source =~ forbidden
    end
  end

  test "dashboard depends on the HTTP bundle and owns Phoenix" do
    dependencies = Mix.Project.config() |> Keyword.fetch!(:deps) |> Enum.map(&elem(&1, 0))

    assert :tay_http in dependencies
    assert :phoenix in dependencies
    assert :phoenix_live_view in dependencies
    refute :tay_core in dependencies
    refute :bandit in dependencies
  end
end
