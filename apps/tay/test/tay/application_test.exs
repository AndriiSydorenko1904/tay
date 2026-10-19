defmodule Tay.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  setup do
    previous_env = Application.get_all_env(:tay)
    :ok = Application.stop(:tay)

    on_exit(fn ->
      Application.stop(:tay)
      for {key, _value} <- Application.get_all_env(:tay), do: Application.delete_env(:tay, key)
      for {key, value} <- previous_env, do: Application.put_env(:tay, key, value)
      {:ok, _apps} = Application.ensure_all_started(:tay)
    end)

    :ok
  end

  @tag :tmp_dir
  test "starts an empty supervisor without creating the configured directory", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "storage-not-created")
    Application.put_env(:tay, :data_dir, target)

    assert {:ok, [:tay]} = Application.ensure_all_started(:tay)
    supervisor = Process.whereis(Tay.Supervisor)
    assert is_pid(supervisor)
    assert Supervisor.which_children(supervisor) == []
    refute File.exists?(target)

    monitor = Process.monitor(supervisor)
    assert :ok = Application.stop(:tay)
    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}
    assert Process.whereis(Tay.Supervisor) == nil
    refute File.exists?(target)

    assert {:ok, [:tay]} = Application.ensure_all_started(:tay)
    refute Process.whereis(Tay.Supervisor) == supervisor
    refute File.exists?(target)
  end

  test "starts without a storage path or configured queues in Phase 0" do
    Application.delete_env(:tay, :data_dir)
    Application.put_env(:tay, :queues, [])

    assert {:ok, [:tay]} = Application.ensure_all_started(:tay)
    assert {:ok, %Tay.Config{data_dir: nil, queues: []}} = Tay.Config.load()
    assert Supervisor.which_children(Tay.Supervisor) == []
  end

  test "the root supervisor supports the standard OTP child specification" do
    supervisor = start_supervised!(Tay.Supervisor)

    assert Process.whereis(Tay.Supervisor) == supervisor
    assert Supervisor.which_children(supervisor) == []
    assert :ok = stop_supervised(Tay.Supervisor)
    assert Process.whereis(Tay.Supervisor) == nil
  end

  test "rejects invalid configuration before registering a supervisor" do
    Application.put_env(:tay, :queues, default: 0)

    assert {:error,
            {:tay, {{:invalid_config, :queues, message}, {Tay.Application, :start, _args}}}} =
             Application.ensure_all_started(:tay)

    assert message == "concurrency limits must be positive integers"
    assert Process.whereis(Tay.Supervisor) == nil

    Application.put_env(:tay, :queues, default: 1)
    assert {:ok, [:tay]} = Application.ensure_all_started(:tay)
  end
end
