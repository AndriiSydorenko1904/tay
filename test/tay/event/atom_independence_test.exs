defmodule Tay.Event.AtomIndependenceTest do
  use ExUnit.Case, async: true
  alias Tay.Test.{EventHelpers, NativeHelpers}

  test "fresh VM accepts unmapped worker/module-looking text without interning or loading it" do
    key = "Elixir.NotLoadedWorker.Phase4.Conformance_783ab06"
    event = EventHelpers.inserted(EventHelpers.definition(%{"worker_key" => key}))
    {:ok, {1, 1, payload}} = Tay.Event.encode(event)

    script = """
    [hex, key] = System.argv()
    payload = Base.decode16!(hex)
    {:ok, event, _} = Tay.Event.decode_payload(1, 1, payload, Tay.Event.Value.defaults())
    true = event.data["definition"]["worker_key"] == key
    result = try do
      :erlang.binary_to_existing_atom(key, :utf8)
      :unexpected_atom
    rescue
      ArgumentError -> :inert
    end
    IO.puts(result)
    """

    assert {"inert\n", 0} = NativeHelpers.child_elixir(script, [Base.encode16(payload), key])
  end
end
