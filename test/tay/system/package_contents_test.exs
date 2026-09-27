defmodule Tay.System.PackageContentsTest do
  use ExUnit.Case, async: true

  test "single Tay package includes dashboard dependencies without Cowboy" do
    dependencies = Mix.Project.config() |> Keyword.fetch!(:deps) |> Enum.map(&elem(&1, 0))

    assert :phoenix in dependencies
    assert :phoenix_live_view in dependencies
    assert :bandit in dependencies
    refute :plug_cowboy in dependencies
    assert :telemetry in dependencies

    mix = File.read!(Path.expand("../../../mix.exs", __DIR__))
    refute mix =~ ~s("dashboard/lib")
    assert mix =~ "docs/dashboard.md"
  end
end
