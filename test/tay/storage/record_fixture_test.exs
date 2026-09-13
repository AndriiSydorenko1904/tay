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
end
