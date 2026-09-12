defmodule Tay.Storage.RecoveryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Storage.{Native, Recovery}
  import Tay.Test.RecoveryHelpers

  property "generated multi-segment histories reproduce the independent sequence/value oracle" do
    check all(
            groups <-
              list_of(list_of(integer(0..255), min_length: 1, max_length: 5),
                min_length: 1,
                max_length: 5
              ),
            max_runs: 30
          ) do
      Process.flag(:trap_exit, true)
      path = Tay.Test.NativeHelpers.path()

      try do
        {segments, _} =
          Enum.with_index(groups, 1)
          |> Enum.map_reduce(1, fn {values, id}, first ->
            records =
              Enum.with_index(values, first)
              |> Enum.map(fn {value, sequence} -> frame(sequence, value) end)

            {segment(id, first, records, id < length(groups)), first + length(values)}
          end)

        store(path, segments)
        {:ok, native} = open(path)

        expected =
          groups
          |> List.flatten()
          |> Enum.with_index(1)
          |> Enum.map(fn {value, sequence} -> {sequence, value} end)
          |> Enum.reverse()

        for _ <- 1..2 do
          assert {:ok, summary, ^expected} =
                   Recovery.replay(native, Tay.Test.RecoveryDecoder, [], &collect/3)

          assert summary.next_sequence == length(expected) + 1
        end

        Native.shutdown(native)
      after
        File.rm_rf!(path)
      end
    end
  end

  property "generated torn suffixes never publish or mutate evidence" do
    check all(value <- integer(0..255), size <- integer(1..28), max_runs: 30) do
      Process.flag(:trap_exit, true)
      path = Tay.Test.NativeHelpers.path()

      try do
        store(path, [segment(1, 1, [frame(1), binary_part(frame(2, value), 0, size)])])
        before = snapshot(path)
        assert {:error, %{kind: :incomplete_tail, mutation: :none}} = start(path)
        assert snapshot(path) == before
      after
        File.rm_rf!(path)
      end
    end
  end
end
