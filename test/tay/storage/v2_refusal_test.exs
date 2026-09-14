defmodule Tay.Storage.V2RefusalTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.{Native, Reader}
  alias Tay.Storage.V2.Authority
  import Tay.Test.RecoveryHelpers

  setup do
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    store(path)
    %{path: path}
  end

  test "V1 reader accepts untouched V1 and refuses explicit V2 root marker", %{path: path} do
    {:ok, native} = open(path)
    assert {:ok, %{store: %{state: :ready}}} = Reader.preflight(native)
    assert :ok = Native.shutdown(native)

    {:ok, marker} = Authority.encode_marker(<<1::128>>)
    File.write!(Path.join(path, "STORE-V2"), marker)

    {:ok, native} = open(path)
    assert {:error, %{reason: :store_v2_requires_v2_recovery}} = Reader.preflight(native)
    assert {:error, %{reason: :store_v2_requires_v2_recovery}} = Reader.inspect_store(native)
    assert :ok = Native.shutdown(native)
  end

  test "V1 reader refuses partially adopted CURRENT even without V2 marker", %{path: path} do
    File.write!(Path.join(path, "CURRENT"), <<0>>)
    {:ok, native} = open(path)
    assert {:error, %{reason: :store_v2_requires_v2_recovery}} = Reader.preflight(native)
    assert :ok = Native.shutdown(native)
  end
end
