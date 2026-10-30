defmodule Tay.Storage.Native.CodecTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Native.Codec
  alias Tay.Storage.Native

  defp fixtures do
    Path.expand("../../fixtures/native/port_v1.json", __DIR__) |> File.read!() |> Jason.decode!()
  end

  defp platform(value) when is_map(value), do: Map.fetch!(value, to_string(elem(:os.type(), 1)))
  defp platform(value), do: value
  defp bytes(hex), do: Base.decode16!(hex, case: :lower)

  defp exchange(request, helper) do
    executable =
      if helper == "fault_enabled", do: "tay_storage_helper_test", else: "tay_storage_helper"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(Application.app_dir(:tay, "priv/" <> executable))},
        [:binary, :exit_status, :use_stdio, {:packet, 4}]
      )

    try do
      assert Port.command(port, request)
      assert_receive {^port, {:data, reply}}, 5_000
      reply
    after
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  test "the frozen catalog covers every opcode including the test-only fault command" do
    expected = Map.new(fixtures(), &{&1["operation"], &1["opcode"]})
    actual = Map.new(Codec.operations(), fn {name, code} -> {Atom.to_string(name), code} end)
    assert expected == actual
    production = Enum.filter(fixtures(), &(&1["helper"] == "production"))
    assert length(production) == map_size(actual)
  end

  test "frozen packets match the codec and both native helper capabilities" do
    for fixture <- fixtures() do
      operation = String.to_existing_atom(fixture["operation"])
      id = fixture["id"]
      request = bytes(fixture["request"])
      reply = fixture["reply"] |> platform() |> bytes()
      assert Codec.encode_request(operation, id, bytes(fixture["body"])) == request
      assert exchange(request, fixture["helper"]) == reply

      if fixture["result"] == "ok" do
        assert Codec.decode_reply(reply, operation, id) == {:ok, <<>>, 0}
      else
        assert {:error, error} = Codec.decode_reply(reply, operation, id)

        assert error == %{
                 kind: :native_io,
                 operation: operation,
                 errno: platform(fixture["errno"]),
                 reason: fixture["result"],
                 bytes_written: 0
               }
      end

      assert Codec.decode_reply(reply, operation, id + 1) == :invalid_reply
    end
  end

  test "malformed bodies and versions are rejected before effects for every opcode" do
    for fixture <- fixtures() do
      operation = String.to_existing_atom(fixture["operation"])
      body = bytes(fixture["body"])
      id = fixture["id"]

      malformed =
        if fixture["variable_payload"] do
          [binary_part(body, 0, fixture["minimum_body_bytes"] - 1)]
        else
          truncated = if body == <<>>, do: [], else: [binary_part(body, 0, byte_size(body) - 1)]
          [body <> <<0>> | truncated]
        end

      requests = Enum.map(malformed, &Codec.encode_request(operation, id, &1))
      requests = [<<2, fixture["opcode"], id::64, body::binary>> | requests]

      for request <- requests do
        reply = exchange(request, fixture["helper"])

        assert {:error, %{reason: "invalid_protocol", bytes_written: 0}} =
                 Codec.decode_reply(reply, operation, id)
      end
    end
  end

  defmodule Capture do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:tay_native_request, _generation, _delegate, operation, body}, _from, owner) do
      send(owner, {:captured_native, operation, body})
      {:reply, {:error, %{kind: :contract_capture}}, owner}
    end
  end

  test "Native API argument packing matches the frozen wire bodies" do
    {:ok, capture} = start_supervised({Capture, self()})

    native = %Native{
      owner: capture,
      port: nil,
      generation: make_ref(),
      delegate: make_ref(),
      cold?: false
    }

    for fixture <- fixtures(),
        fixture["helper"] == "production",
        fixture["operation"] not in [
          "acquire",
          "acquire_existing",
          "acquire_if_missing",
          "cold_target_open",
          "shutdown"
        ] do
      operation = String.to_existing_atom(fixture["operation"])
      assert {:error, %{kind: :contract_capture}} = invoke(native, operation)
      assert_receive {:captured_native, ^operation, body}
      assert body == bytes(fixture["body"]), "body mismatch for #{operation}"
    end
  end

  @zero <<0::128>>
  @epoch "e-" <> String.duplicate("0", 32)
  @stage ".tay-new-00000000000000000001-" <> String.duplicate("0", 32) <> ".tmp"
  @canonical "00000000000000000001.tay"
  defp invoke(n, :list), do: Native.list(n, :root)
  defp invoke(n, :mkdir), do: Native.mkdir_segments(n)
  defp invoke(n, :open_read), do: Native.open_read(n, :segments, @canonical)
  defp invoke(n, :read), do: Native.read(n, 0, 1)
  defp invoke(n, :create_stage), do: Native.create_stage(n, :segments, @stage)

  defp invoke(n, :open_active),
    do: Native.open_active(n, @canonical, %{size: 0, device: 1, inode: 2})

  defp invoke(n, :write), do: Native.write(n, 0, "abc")

  defp invoke(n, :publish),
    do: Native.publish(n, :segments, @stage, @canonical, %{device: 1, inode: 2})

  defp invoke(n, :sync_dir), do: Native.sync_dir(n, :root)
  defp invoke(n, :cold_stage_create), do: Native.cold_create_stage(n, "stage", @epoch)
  defp invoke(n, :cold_open_write), do: Native.cold_open_write(n, :root, "data")
  defp invoke(n, :cold_list), do: Native.cold_list(n, :root, 1)
  defp invoke(n, :v2_select), do: Native.v2_select(n, @zero)
  defp invoke(n, :v2_begin), do: Native.v2_begin(n, @zero)
  defp invoke(n, :v2_publish_epoch), do: Native.v2_publish_epoch(n, @zero)

  defp invoke(n, :v2_publish_current),
    do:
      Native.v2_publish_current(
        n,
        ".tay-current-" <> String.duplicate("0", 32) <> ".tmp",
        %{device: 1, inode: 2},
        nil
      )

  defp invoke(n, :v2_reclaim), do: Native.v2_reclaim(n, @epoch, <<0::608>>)
  defp invoke(n, :fault), do: Native.fault(n, :write, 1, :error, 5, 0)
  defp invoke(n, operation), do: apply(Native, operation, [n])

  test "invalid envelopes cannot be mistaken for an acknowledged operation" do
    for reply <- [
          <<>>,
          <<2, 17, 1::64, 0, 0::32, 0::64>>,
          <<1, 14, 1::64, 0, 0::32, 0::64>>,
          <<1, 17, 2::64, 0, 0::32, 0::64>>,
          <<1, 17, 1::64, 0, 9::32, 0::64>>
        ] do
      assert Codec.decode_reply(reply, :shutdown, 1) == :invalid_reply
    end

    assert {:error, %{bytes_written: :unknown}} =
             Codec.decode_reply(
               <<1, 9, 1::64, 1, 5::32, 18_446_744_073_709_551_615::64, "eio">>,
               :write,
               1
             )
  end

  test "metadata decoding distinguishes cold-copy timestamps and rejects truncation" do
    identity = <<44::64, 1::64, 2::64, 1::64, 1, 384::32>>
    assert {:ok, %{size: 44, type: :regular, mode: 384}, <<>>} = Codec.identity(identity, false)
    assert :error = Codec.identity(identity, true)

    assert {:ok, %{mtime_ns: 10, ctime_ns: 20}, <<>>} =
             Codec.identity(<<identity::binary, 10::64, 20::64>>, true)

    assert {:ok, [%{name: "a", inode: 2}]} =
             Codec.entries(<<1::16, "a", identity::binary>>, 1, [], false)

    assert :error = Codec.entries(<<1::16, "a", identity::binary>>, 2, [], false)
  end
end
