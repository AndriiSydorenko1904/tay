defmodule Tay.Storage.RecordIsolationTest do
  use ExUnit.Case, async: false
  alias Tay.Storage.Record
  alias Tay.Test.RecordHelpers, as: H

  test "insertion configuration and semantic registry environment cannot change physical results" do
    keys = [:max_insert_payload_bytes, :supported_schemas]
    previous = for key <- keys, do: {key, Application.fetch_env(:tay, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:tay, key, original)
          :error -> Application.delete_env(:tay, key)
        end
      end
    end)

    # Test-only environment sentinels; no settings are added to Tay.Config.
    Application.put_env(:tay, :max_insert_payload_bytes, 0)
    Application.put_env(:tay, :supported_schemas, %{})

    for id <- ["F02", "F07", "F09"] do
      {:ok, record, <<>>} = H.expected(H.fixture(id))
      bytes = H.bytes(id)
      assert Record.encode(record) == {:ok, bytes}
      assert Record.decode(bytes) == {:ok, record, <<>>}
    end

    assert Record.decode(H.bytes("F04")) == {:error, {:corrupt, :header_checksum}}
    assert Record.decode(H.bytes("F10")) == H.expected(H.fixture("F10"))
  end

  test "ETF-looking payloads remain opaque and do not intern runtime atom/module names" do
    for prefix <- ["tay_phase1_atom_", "Elixir.Tay.Phase1UnloadedWorker"] do
      name = prefix <> Integer.to_string(System.unique_integer([:positive]))
      assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(name, :utf8) end
      # ETF VERSION_MAGIC + SMALL_ATOM_UTF8_EXT. These bytes are deliberately
      # not decoded; this is an opacity regression test, not a payload schema.
      payload = <<131, 119, byte_size(name), name::binary>>
      bytes = H.frame(record_type: 47, payload_schema_version: 3, payload: payload)
      record = H.record(record_type: 47, payload_schema_version: 3, payload: payload)
      assert Record.decode(bytes) == {:ok, record, <<>>}
      assert Record.encode(record) == {:ok, bytes}
      assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(name, :utf8) end
    end
  end
end
