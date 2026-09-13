defmodule Tay.Executor.ProtocolTest do
  use ExUnit.Case, async: true

  alias Tay.Executor.Protocol

  test "decodes fragmented and coalesced bounded frames" do
    first = %{"version" => 1, "type" => "hello", "request_id" => "one"}
    second = %{"version" => 1, "type" => "heartbeat", "request_id" => "two"}
    assert {:ok, first_frame} = Protocol.frame(first)
    assert {:ok, second_frame} = Protocol.frame(second)

    <<head::binary-size(5), tail::binary>> = first_frame
    assert {:ok, [], ^head} = Protocol.decode_frames(head)
    assert {:ok, [^first, ^second], <<>>} = Protocol.decode_frames(head <> tail <> second_frame)
  end

  test "rejects invalid public envelopes before they reach a connection" do
    assert {:error, :unsupported_version} =
             Protocol.decode_message(~s({"version":2,"type":"hello","request_id":"x"}))

    assert {:error, :invalid_request_id} =
             Protocol.decode_message(~s({"version":1,"type":"hello"}))

    assert {:error, :frame_too_large} =
             Protocol.decode_frames(<<65_537::unsigned-big-32>>, 65_536)
  end
end
