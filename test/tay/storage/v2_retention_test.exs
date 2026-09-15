defmodule Tay.Storage.V2RetentionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Event.V1
  alias Tay.Storage.V2.{Authority, Retention}
  @directory Path.expand("../../fixtures/storage/v2/phase_c", __DIR__)

  defp fixtures do
    @directory
    |> Path.join("manifests.hex")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [label, hex] = String.split(line, " ")
      {label, Base.decode16!(hex, case: :lower)}
    end)
  end

  test "literal infinite/bounded/maximal manifests and CURRENT preserve schema-1 binding" do
    all = fixtures()

    for {label, policy} <- [
          {"infinity", :infinity},
          {"bounded", {:hours, 24}},
          {"maximum", {:hours, Retention.max_hours()}}
        ] do
      assert {:ok, manifest} = Authority.decode_manifest(all[label])
      assert manifest.terminal_retention == policy
      assert {:ok, encoded} = Authority.encode_manifest(manifest)
      assert encoded == all[label]
      assert <<"TAYM", 1, 0::24, _::binary>> = encoded
    end

    current =
      @directory
      |> Path.join("current.hex")
      |> File.read!()
      |> String.trim()
      |> Base.decode16!(case: :lower)

    assert {:ok, marker} = Authority.encode_marker(<<1::128>>)
    assert {:ok, selected} = Authority.verify_selection(marker, current, all["bounded"])
    assert selected.terminal_retention == {:hours, 24}
    assert {:ok, pointer} = Authority.decode_current(current)
    assert {:ok, ^current} = Authority.encode_current(pointer)
  end

  test "validly checksummed malformed literal retention never falls back to infinity" do
    for {label, bytes} <- fixtures(), label not in ["infinity", "bounded", "maximum"] do
      assert {:error, :terminal_retention} = Authority.decode_manifest(bytes), label
    end

    for policy <- [
          nil,
          false,
          24,
          "24h",
          {:days, 1},
          {:hours, 0},
          {:hours, -1},
          {:hours, 1.0},
          {:hours, Retention.max_hours() + 1}
        ] do
      assert {:error, :terminal_retention} = Retention.validate(policy)
    end
  end

  test "hour bound derives from durable time; equality expires and no time addition can overflow" do
    max = Retention.max_hours()
    assert max == div(V1.max_time(), 3_600_000)
    assert {:ok, duration} = Retention.duration({:hours, max})
    assert duration <= V1.max_time()
    assert (max + 1) * 3_600_000 > V1.max_time()
    assert {:error, :terminal_retention} = Retention.duration({:hours, max + 1})

    for {at, expired} <- [{999, true}, {1_000, true}, {1_001, false}] do
      assert {:ok, ^expired} = Retention.expired?(at, {:hours, 1}, 3_601_000)
    end

    assert {:ok, false} = Retention.expired?(0, {:hours, max}, 0)
    assert {:ok, false} = Retention.expired?(V1.max_time(), {:hours, max}, V1.max_time())
  end

  property "accepted duration and subtraction stay within the existing signed durable range" do
    check all(
            hours <- integer(1..Retention.max_hours()),
            now <- integer(0..V1.max_time()),
            at <- integer(0..V1.max_time())
          ) do
      assert {:ok, duration} = Retention.duration({:hours, hours})
      assert duration <= V1.max_time()
      assert {:ok, actual} = Retention.expired?(at, {:hours, hours}, now)
      assert actual == (now >= duration and at <= now - duration)
      assert now - duration >= -V1.max_time()
    end
  end
end
