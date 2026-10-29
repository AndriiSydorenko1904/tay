defmodule Tay.Protocol.JobOptionsContractTest do
  use ExUnit.Case, async: true

  test "shared Python/Elixir options contract fixes names, limits, units and conflicts" do
    contract =
      "clients/python/tests/fixtures/job_options_v1.json" |> File.read!() |> Jason.decode!()

    assert contract["contract"] == "tay-job-options-v1"

    for fixture <- contract["cases"] do
      result = Tay.Protocol.JobOptions.parse(fixture["options"])

      if fixture["valid"] do
        assert {:ok, parsed} = result, fixture["name"]

        canonical =
          Map.new(parsed, fn {key, value} ->
            {Atom.to_string(key), if(is_atom(value), do: Atom.to_string(value), else: value)}
          end)

        assert canonical == fixture["canonical"], fixture["name"]
      else
        assert {:error, _} = result, fixture["name"]
      end
    end
  end
end
