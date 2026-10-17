defmodule Tay.Storage.OwnershipTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Native
  import Tay.Test.NativeHelpers

  setup do
    path = path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "a second independent BEAM cannot take ownership; stale inode is reusable", %{path: path} do
    {:ok, n} = native(path)
    inode = File.stat!(Path.join(path, ".tay-owner.lock")).inode
    # A bogus/stale PID is irrelevant: ownership is the kernel lock, not content.
    File.write!(Path.join(path, ".tay-owner.lock"), "999999\n")

    script =
      "Process.flag(:trap_exit, true); case Tay.Storage.Native.open(hd(System.argv()), durability: :write) do {:ok, n} -> IO.puts(\"acquired\"); Tay.Storage.Native.close(n); {:error, e} -> IO.puts(e.reason) end"

    assert {"store_busy\n", 0} = child_elixir(script, [path])
    Native.close(n)
    assert {"acquired\n", 0} = child_elixir(script, [path])
    assert File.stat!(Path.join(path, ".tay-owner.lock")).inode == inode
  end

  test "helper death releases ownership and produces an uncertain connection", %{path: path} do
    {:ok, n} = native(path)
    :ok = Native.fault(n, :check, 1, :crash_before)
    assert {:error, %{kind: :uncertain}} = Native.check(n)
    {:ok, reopened} = native(path)
    Native.close(reopened)
  end

  test "symlink and hard-link lock aliases are refused without changing targets", %{path: path} do
    File.mkdir!(path)
    target = Path.join(path, "operator-file")
    lock = Path.join(path, ".tay-owner.lock")
    File.write!(target, "untouched")
    File.ln_s!(target, lock)
    assert {:error, _} = native(path)
    assert File.read!(target) == "untouched"
    File.rm!(lock)
    File.ln!(target, lock)
    assert {:error, %{reason: "hard_link"}} = native(path)
    assert File.read!(target) == "untouched"
  end

  test "lock path replacement and lost FD prevent subsequent operations", %{path: path} do
    {:ok, n} = native(path)
    File.rename!(Path.join(path, ".tay-owner.lock"), Path.join(path, "retired-lock"))
    File.write!(Path.join(path, ".tay-owner.lock"), "")
    assert {:error, %{reason: "path_or_extent_changed"}} = Native.check(n)
    Native.close(n)
  end
end
