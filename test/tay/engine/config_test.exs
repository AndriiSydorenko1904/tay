defmodule Tay.Engine.ConfigTest do
  use ExUnit.Case, async: true
  alias Tay.Engine.Config

  test "appendix option names, defaults, exact domains and conservative cross-budget checks" do
    base = [data_dir: "tmp/config-only", durability: :write]
    assert {:ok, c} = Config.new(base)

    assert {c.max_insert_payload_bytes, c.max_insert_args_bytes, c.insert_value_depth,
            c.insert_value_nodes} == {1_048_576, 262_144, 32, 10_000}

    for extra <- [
          [max_insert_payload_bytes: 0],
          [max_insert_payload_bytes: 16_777_217],
          [max_insert_args_bytes: 4],
          [max_insert_args_bytes: 16_777_217],
          [insert_value_depth: 0],
          [insert_value_nodes: 0],
          [insert_depth: 32],
          [rotation_target_bytes: 1],
          [rotation_target_bytes: 1_073_741_825],
          [recovery: [max_decode_payload_bytes: 1024]],
          [
            recovery: [event_limits: %{depth: 31, output_nodes: 10_000, binary_bytes: 16_777_216}]
          ],
          [recovery: [event_limits: %{depth: 64, output_nodes: 9999, binary_bytes: 16_777_216}]],
          [recovery: [event_limits: %{depth: 64, output_nodes: 100_000, binary_bytes: 1024}]],
          [name: "never-create-atom"],
          [workers: %{"" => __MODULE__}],
          [workers: %{"w" => "Elixir.NeverFromDisk"}],
          [client_slots: 0],
          [client_bytes: 1],
          [caller_timeout: :infinity],
          [bootstrap: true]
        ],
        do: assert({:error, %Tay.Error{kind: :invalid}} = Config.new(Keyword.merge(base, extra)))

    assert {:ok, _} = Config.new(base ++ [max_insert_payload_bytes: 1, max_insert_args_bytes: 5])
    assert {:error, _} = Config.new(base ++ [durability: :write])
    assert {:error, _} = Config.new(:bad)
  end

  test "sync has no silent platform or unvalidated-filesystem fallback" do
    assert {:error, _} = Config.new(data_dir: "tmp/config-only", durability: :sync)

    if :os.type() != {:unix, :linux} do
      assert {:error, _} =
               Config.new(
                 data_dir: "tmp/config-only",
                 durability: :sync,
                 validated_filesystem: true
               )
    end
  end
end
