defmodule Tay.Execution.RateLimitIntegrationTest do
  use ExUnit.Case, async: false
  alias Tay.Test.ExecutionHelpers, as: H
  alias Tay.Test.NativeHelpers
  @name __MODULE__

  test "durable starts consume credit, pending work stays ready and resumes after the window" do
    Process.flag(:trap_exit, true)
    H.install()
    path = NativeHelpers.path()
    H.initialize(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, root} =
      H.start(path, @name,
        queues: [default: 2],
        rate_limits: [queues: %{"default" => %{limit: 1, interval_ms: 100}}]
      )

    on_exit(fn ->
      try do
        H.stop(root)
      catch
        :exit, _ -> :ok
      end
    end)

    {first, first_token} = H.job()
    {second, second_token} = H.job()
    assert {:ok, _} = Tay.insert(first, name: @name)
    {task, _} = H.await_entry(first_token)
    assert {:ok, _} = Tay.insert(second, name: @name)

    assert H.eventually(fn ->
             match?({:ok, %{state: :available}}, Tay.get_job(second.id, name: @name))
           end)

    refute_receive {:tay_test_entered, ^second_token, _, _}, 30
    send(task, {:return, :ok})
    H.await_job(@name, first.id, :completed)
    H.set_clock(1_000_100, 100)
    {task, _} = H.await_entry(second_token)
    send(task, {:return, :ok})
    H.await_job(@name, second.id, :completed)
  end
end
