defmodule Tay.Storage.SupervisionTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Writer
  import Tay.Test.NativeHelpers

  setup do
    Process.flag(:trap_exit, true)
    path = path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  test "idle helper death poisons the same supervised writer without restarting it", %{path: path} do
    parent = self()

    hook = fn
      {:poisoned, reason}, _ ->
        send(parent, {:poisoned, reason})
        :ok

      _, _ ->
        :ok
    end

    w =
      start_supervised!(
        {Writer, [data_dir: path, durability: :write, test_helper: true, on_transition: hook]}
      )

    {:ok, _} = Writer.append(w, 1, 1, "acknowledged")
    pid = Writer.status(w).os_pid
    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
    assert_receive {:poisoned, _}, 5_000
    assert Process.alive?(w)
    assert Writer.status(w).state == :poisoned
    assert {:error, {:poisoned, _}} = Writer.append(w, 1, 1, "forbidden")
    {:ok, other} = Writer.start_link(data_dir: path, durability: :write)
    assert Writer.status(other).next_sequence == 2
    GenServer.stop(other)
  end

  test "writer death does not trigger automatic supervisor mutation retries", %{path: path} do
    w = start_supervised!({Writer, [data_dir: path, durability: :write]})
    {:ok, _} = Writer.append(w, 1, 1, "acknowledged")
    ref = Process.monitor(w)
    Process.exit(w, :kill)
    assert_receive {:DOWN, ^ref, :process, ^w, :killed}

    script =
      "Process.flag(:trap_exit, true); {:ok, w} = Tay.Storage.Writer.start_link(data_dir: hd(System.argv()), durability: :write); IO.puts(Tay.Storage.Writer.status(w).next_sequence); GenServer.stop(w)"

    assert {"2\n", 0} = child_elixir(script, [path])
    refute Process.alive?(w)
  end

  test "an abrupt independent BEAM exit preserves acknowledged physical bytes", %{path: path} do
    script =
      "Process.flag(:trap_exit, true); {:ok, w} = Tay.Storage.Writer.start_link(data_dir: hd(System.argv()), durability: :write); {:ok, r} = Tay.Storage.Writer.append(w, 47, 3, <<0,255>>); IO.puts(\"ACK:\" <> Integer.to_string(r.sequence)); System.halt(23)"

    assert {"ACK:1\n", 23} = child_elixir(script, [path])
    {:ok, w} = Writer.start_link(data_dir: path, durability: :write)
    assert Writer.status(w).next_sequence == 2
    assert {:ok, [<<0, 255>>]} = Writer.reduce(w, [], fn r, _, acc -> [r.payload | acc] end)
    GenServer.stop(w)
  end
end
