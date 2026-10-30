defmodule Tay.State.MemoryTest do
  use ExUnit.Case, async: true
  alias Tay.State.Memory

  test "concurrent reservations cannot spend the same free bytes" do
    memory = Memory.new(100)

    results =
      1..100
      |> Task.async_stream(fn _ -> Memory.reserve(memory, 3) end, max_concurrency: 32)
      |> Enum.to_list()

    assert Enum.count(results, &(&1 == {:ok, :ok})) == 33
    assert Memory.used(memory) == 99
    Memory.release(memory, 99)
    assert Memory.used(memory) == 0
  end

  test "completion keeps released credit private until its result is retained" do
    memory = Memory.new(100)
    assert :ok = Memory.reserve(memory, 100)

    Memory.settling(memory, fn ->
      assert {:ok, :finished} = Memory.transaction(memory, -80, fn -> {:ok, :finished} end)
      assert Memory.used(memory) == 100
      assert {:error, _} = Task.async(fn -> Memory.reserve(memory, 1) end) |> Task.await()
      assert {:ok, :result} = Memory.transaction(memory, 30, fn -> {:ok, :result} end)
    end)

    assert Memory.used(memory) == 50
  end

  test "failed writes release reservations and checkpoint adoption rebases a commit" do
    memory = Memory.new(100)
    assert :ok = Memory.reserve(memory, 70)

    assert {:error, :write_failed} =
             Memory.transaction(memory, 20, fn -> {:error, :write_failed} end)

    assert Memory.used(memory) == 70

    assert {:ok, :published} =
             Memory.transaction(memory, -10, fn ->
               assert {:ok, :checkpoint} =
                        Memory.transaction(memory, -20, fn -> {:ok, :checkpoint} end)

               {:memory_delta, 10, {:ok, :published}}
             end)

    assert Memory.used(memory) == 60
  end
end
