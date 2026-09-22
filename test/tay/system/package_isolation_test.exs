defmodule Tay.System.PackageIsolationTest do
  use ExUnit.Case, async: true

  test "core dependency and package manifests exclude web libraries and dashboard sources" do
    dependencies = Mix.Project.config() |> Keyword.fetch!(:deps) |> Enum.map(&elem(&1, 0))

    refute :phoenix in dependencies
    refute :phoenix_live_view in dependencies
    refute :plug in dependencies
    assert :telemetry in dependencies

    mix = File.read!(Path.expand("../../../mix.exs", __DIR__))
    refute mix =~ ~s("dashboard/lib")
    refute mix =~ "phoenix"
    refute mix =~ "live_view"
    refute mix =~ "plug"
  end
end
