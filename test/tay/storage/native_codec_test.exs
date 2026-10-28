defmodule Tay.Storage.Native.CodecTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Native.Codec

  test "frozen protocol packets match both the codec and the production C helper" do
    fixtures = Path.expand("../../fixtures/native/port_v1.json", __DIR__)

    for fixture <- fixtures |> File.read!() |> Jason.decode!() do
      operation = String.to_existing_atom(fixture["operation"])
      id = fixture["id"]
      request = Base.decode16!(fixture["request"], case: :lower)
      reply = Base.decode16!(fixture["reply"], case: :lower)

      assert Codec.encode_request(operation, id, Base.decode16!(fixture["body"], case: :lower)) ==
               request

      port =
        Port.open(
          {:spawn_executable,
           String.to_charlist(Application.app_dir(:tay, "priv/tay_storage_helper"))},
          [:binary, :exit_status, :use_stdio, {:packet, 4}]
        )

      try do
        assert Port.command(port, request)
        assert_receive {^port, {:data, ^reply}}, 5_000

        case fixture["result"] do
          "ok" ->
            assert Codec.decode_reply(reply, operation, id) == {:ok, <<>>, 0}

          "ebadf" ->
            assert {:error,
                    %{
                      kind: :native_io,
                      operation: ^operation,
                      errno: 9,
                      reason: "ebadf",
                      bytes_written: 0
                    }} =
                     Codec.decode_reply(reply, operation, id)
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  end

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
