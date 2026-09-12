defmodule Tay.Storage.RecordFixtureTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Record
  alias Tay.Test.RecordHelpers, as: H

  for fixture <- H.fixtures() do
    @fixture fixture
    test "decodes permanent fixture #{fixture.id} to its exact physical result" do
      bytes = H.bytes(@fixture.id)
      assert bytes == Base.decode16!(@fixture.hex)
      assert Record.decode(bytes) == H.expected(@fixture)
      assert Record.decode(bytes, []) == H.expected(@fixture)
    end
  end

  test "all 18 binary anchors exactly match the approved RFC literals" do
    rfc = File.read!(Path.expand("../../../docs/phase-1-storage-format-rfc.md", __DIR__))

    literals =
      Regex.scan(~r/\*\*(F\d{2}) —[^\n]*[\s\S]*?```text\n([\s\S]*?)\n```/, rfc)
      |> Map.new(fn [_match, id, hex] ->
        {id, hex |> String.replace(~r/\s+/, "") |> String.upcase()}
      end)

    assert map_size(literals) == 18
    assert length(H.fixtures()) == 18

    for fixture <- H.fixtures() do
      assert fixture.hex == Map.fetch!(literals, fixture.id)
      assert H.bytes(fixture.id) == Base.decode16!(fixture.hex)
    end
  end
end
