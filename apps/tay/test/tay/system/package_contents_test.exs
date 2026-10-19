defmodule Tay.System.PackageContentsTest do
  use ExUnit.Case, async: true

  test "core package excludes optional HTTP and dashboard stacks" do
    dependencies = Mix.Project.config() |> Keyword.fetch!(:deps) |> Enum.map(&elem(&1, 0))

    refute :phoenix in dependencies
    refute :phoenix_live_view in dependencies
    refute :bandit in dependencies
    refute :plug_cowboy in dependencies
    assert :telemetry in dependencies
    assert :telemetry_metrics in dependencies

    source = Path.expand("../../../lib", __DIR__)
    refute File.exists?(Path.join(source, "tay/http"))
    refute File.exists?(Path.join(source, "tay/dashboard"))
  end
end
