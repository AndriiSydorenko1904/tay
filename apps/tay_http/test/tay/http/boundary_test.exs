defmodule Tay.HTTP.BoundaryTest do
  use ExUnit.Case, async: true

  test "HTTP transport owns Bandit without pulling in Phoenix" do
    dependencies = Mix.Project.config() |> Keyword.fetch!(:deps) |> Enum.map(&elem(&1, 0))

    assert :tay_core in dependencies
    assert :bandit in dependencies
    refute :phoenix in dependencies
    refute :phoenix_live_view in dependencies
  end
end
