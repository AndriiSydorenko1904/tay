defmodule Tay.Execution.RetryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Event.V1
  alias Tay.Execution.Retry

  defp job(attempt),
    do: %{
      attempt: attempt,
      definition: %{"max_attempts" => 65_535, "retry_policy" => V1.policy()}
    }

  test "literal retry bounds and saturation are the stored v1 policy, not current defaults" do
    for {ordinal, low, high} <- [
          {1, 1000, 1250},
          {2, 2000, 2500},
          {3, 4000, 5000},
          {4, 8000, 10_000},
          {5, 16_000, 20_000},
          {6, 32_000, 40_000},
          {7, 60_000, 60_000},
          {65_535, 60_000, 60_000}
        ] do
      assert {:ok, ^low} = Retry.due_at(job(ordinal), 0, fn 2 -> <<0::16>> end)

      assert {:ok, ^high} =
               Retry.due_at(job(ordinal), 0, fn 2 -> <<high - low::16>> end)

      maximum = V1.max_time()
      assert {:ok, ^maximum} = Retry.due_at(job(ordinal), maximum - 1, fn 2 -> <<0::16>> end)
    end

    assert {:ok, 60_000} =
             Retry.due_at(job(7), 0, fn _ -> flunk("zero jitter must not consume randomness") end)

    for invalid <- [0, 65_536, 1.0] do
      assert {:error, :invalid_retry_context} = Retry.due_at(job(invalid), 0)
    end

    assert {:error, :invalid_retry_context} = Retry.due_at(job(1), -1)

    bad_policy = put_in(job(1), [:definition, "retry_policy", "base_ms"], 1001)
    assert {:error, :invalid_retry_context} = Retry.due_at(bad_policy, 0)
    bad_maximum = put_in(job(2), [:definition, "max_attempts"], 1)
    assert {:error, :invalid_retry_context} = Retry.due_at(bad_maximum, 0)
  end

  test "rejection sampling refuses the unequal suffix and yields every inclusive residue equally" do
    # For N=6 there are 8001 residues and eight full repetitions in 16 bits.
    cutoff = 64_008
    Process.put(:retry_draws, [<<cutoff::16>>, <<65_535::16>>, <<8000::16>>])

    source = fn 2 ->
      [head | rest] = Process.get(:retry_draws)
      Process.put(:retry_draws, rest)
      head
    end

    assert {:ok, 40_000} = Retry.due_at(job(6), 0, source)
    assert Process.get(:retry_draws) == []

    # Enumerate the entire accepted prefix independently rather than sampling a
    # probabilistic histogram. Every possible jitter has exactly eight images.
    counts =
      Enum.reduce(0..(cutoff - 1), %{}, fn sample, counts ->
        {:ok, due} = Retry.due_at(job(6), 0, fn 2 -> <<sample::16>> end)
        Map.update(counts, due - 32_000, 1, &(&1 + 1))
      end)

    assert map_size(counts) == 8001
    assert Enum.all?(counts, fn {jitter, count} -> jitter in 0..8000 and count == 8 end)
  end

  test "failed or repeatedly rejected entropy is bounded and never creates an invented due time" do
    Process.put(:draw_count, 0)

    assert {:error, :random_source_failed} =
             Retry.due_at(job(6), 0, fn 2 ->
               Process.put(:draw_count, Process.get(:draw_count) + 1)
               <<65_535::16>>
             end)

    assert Process.get(:draw_count) == 128

    for source <- [
          fn _ -> <<>> end,
          fn _ -> <<0, 0, 0>> end,
          fn _ -> raise "entropy unavailable" end,
          fn _ -> throw(:failed) end,
          fn _ -> exit(:failed) end
        ] do
      assert {:error, :random_source_failed} = Retry.due_at(job(1), 0, source)
    end
  end

  property "chosen due is always in the immutable decoder interval, including end-of-time saturation" do
    check all(
            ordinal <- integer(1..65_535),
            at <- one_of([integer(0..V1.max_time()), member_of([0, V1.max_time()])]),
            max_runs: 100
          ) do
      assert {:ok, due} = Retry.due_at(job(ordinal), at)
      {low, high} = V1.retry_interval(at, ordinal)
      assert due in low..high
      assert due >= at and due <= V1.max_time()
    end
  end
end
