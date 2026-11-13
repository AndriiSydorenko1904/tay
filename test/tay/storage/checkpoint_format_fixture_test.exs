defmodule Tay.Storage.CheckpointFormatFixtureTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{DiskIndex, V2.CheckpointIndex, V2.RecoveryIndex}

  test "the frozen format-2 descriptor and cross-epoch page remain readable" do
    fixture =
      Path.expand("../../fixtures/storage/v2/checkpoint_index/format2.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    decode = &Base.decode16!(&1, case: :lower)
    epoch = decode.(fixture["epoch"])
    wire = decode.(fixture["descriptor"])
    assert {:ok, value} = Tay.Event.Value.decode(wire)
    assert {:ok, descriptor} = RecoveryIndex.from_value(value)
    assert CheckpointIndex.valid?(descriptor)
    assert descriptor.format == 2
    assert CheckpointIndex.count(descriptor) == 1
    assert CheckpointIndex.count(descriptor, :work) == 1
    assert decode.(fixture["header"]) == <<"TAYI", 2, 0::472>>
    pages = Map.new(fixture["pages"], &{&1["offset"], decode.(&1["bytes"])})

    read = fn source, at, size ->
      assert source == epoch
      bytes = Map.fetch!(pages, at)
      assert byte_size(bytes) == size
      {:ok, bytes}
    end

    assert {:ok, root} = DiskIndex.decode_root(descriptor.root)

    assert {:ok, %{"epoch" => {:bytes, <<34::128>>}, "segment" => 1, "offset" => 44}} =
             DiskIndex.fetch(read, root, decode.(fixture["key"]))

    assert {:ok, ^wire} = Tay.Event.Value.encode(RecoveryIndex.to_value(descriptor))
    assert {:ok, objects} = CheckpointIndex.objects(descriptor)
    assert DiskIndex.object(epoch, 0, 0) in objects
    assert DiskIndex.object(<<34::128>>, 1, 1, 236) in objects
  end

  test "the frozen empty format-3 descriptor remains byte compatible" do
    fixture =
      Path.expand("../../fixtures/storage/v2/checkpoint_index/format3-empty.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    wire = Base.decode16!(fixture["descriptor"], case: :lower)
    assert {:ok, value} = Tay.Event.Value.decode(wire)
    assert {:ok, descriptor} = RecoveryIndex.from_value(value)
    assert CheckpointIndex.valid?(descriptor)
    assert descriptor.format == 3
    assert Enum.all?(CheckpointIndex.roles(), &(CheckpointIndex.count(descriptor, &1) == 0))
    assert Base.decode16!(fixture["header"], case: :lower) == <<"TAYI", 3, 0::472>>
    assert {:ok, ^wire} = Tay.Event.Value.encode(RecoveryIndex.to_value(descriptor))
    assert {:ok, []} = CheckpointIndex.objects(descriptor)
  end
end
