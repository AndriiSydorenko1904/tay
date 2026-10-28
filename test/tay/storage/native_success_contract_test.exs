defmodule Tay.Storage.Native.SuccessContractTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.Native
  alias Tay.Storage.Native.Codec
  alias Tay.Test.NativeHelpers, as: H

  @canonical "00000000000000000001.tay"
  @file_bytes "0123456789abcdef0123456789abcdef0123456789ab"

  defp fixtures do
    Path.expand("../../fixtures/native/port_v1_success.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp bytes(hex), do: Base.decode16!(hex, case: :lower)

  test "successful reply bodies freeze data, metadata, owner facts and write counts" do
    for f <- fixtures() do
      op = String.to_existing_atom(f["operation"])
      assert Codec.encode_request(op, f["id"], bytes(f["body"])) == bytes(f["request"])

      assert Codec.decode_reply(bytes(f["reply"]), op, f["id"]) ==
               {:ok, bytes(f["payload"]), f["bytes_written"]}

      decoded = decode(f, bytes(f["payload"]))
      assert decoded != :error

      if f["decoder"] in ["identity", "entries", "info", "acquisition", "space"] do
        payload = bytes(f["payload"])
        assert decode(f, binary_part(payload, 0, byte_size(payload) - 1)) == :error
        assert decode(f, payload <> <<0>>) == :error
      end
    end
  end

  defmodule Reply do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call({:tay_native_request, _, _, op, body}, _, {owner, reply} = state) do
      send(owner, {:packed, op, body})
      {:reply, reply, state}
    end
  end

  test "Native APIs decode the same successful packets and pack their frozen requests" do
    for f <- fixtures(), f["operation"] != "acquire" do
      op = String.to_existing_atom(f["operation"])
      payload = bytes(f["payload"])
      reply = Codec.decode_reply(bytes(f["reply"]), op, f["id"])
      owner = start_supervised!({Reply, {self(), reply}}, id: make_ref())

      native = %Native{
        owner: owner,
        port: nil,
        generation: make_ref(),
        delegate: make_ref(),
        cold?: false
      }

      assert invoke(native, f) == expected_api(f, payload)
      assert_receive {:packed, ^op, body}
      assert body == bytes(f["body"])
    end
  end

  test "production helper emits successful golden payloads in a real ownership session" do
    Process.flag(:trap_exit, true)

    for f <- fixtures(), f["setup"] != nil do
      path = H.path()
      assert {:ok, native} = Native.open(path, durability: :write)

      try do
        assert :ok = Native.mkdir_segments(native)
        setup_file(native, f["setup"])
        op = String.to_existing_atom(f["operation"])
        assert Port.command(native.port, bytes(f["request"]))
        assert_receive {port, {:data, reply}}, 5_000
        assert port == native.port
        assert {:ok, payload, written} = Codec.decode_reply(reply, op, f["id"])
        payload = normalize_host_fields(payload, f, native, path)
        normalized = <<1, f["opcode"], f["id"]::64, 0, 0::32, written::64, payload::binary>>
        assert normalized == bytes(f["reply"]), f["name"]
      after
        Native.shutdown(native)
        File.rm_rf!(path)
      end
    end
  end

  defp setup_file(_, "empty"), do: :ok

  defp setup_file(native, "write") do
    assert {:ok, _} = Native.create_stage(native, :segments, H.stage())
  end

  defp setup_file(native, kind) do
    stage = H.stage()
    assert {:ok, identity} = Native.create_stage(native, :segments, stage)
    assert {:ok, %{written: 44}} = Native.write(native, 0, @file_bytes)
    assert :ok = Native.close_write(native)
    assert :ok = Native.publish(native, :segments, stage, @canonical, identity)
    if kind == "read", do: assert({:ok, _} = Native.open_read(native, :segments, @canonical))
  end

  # Only OS-generated identities, process IDs and free space are normalized.
  # Their actual values are checked independently against the pinned store and
  # filesystem. Data, flags, lengths, field order and write counts remain exact.
  defp normalize_host_fields(payload, %{"decoder" => "identity"} = f, _native, path) do
    target =
      if f["setup"] == "write",
        do: Path.join(path <> "/segments", only_stage(path)),
        else: path <> "/segments/" <> @canonical

    verify_identity(payload, target)
    normalize_identity(payload)
  end

  defp normalize_host_fields(
         <<1::32, n::16, name::binary-size(n), identity::binary>>,
         %{"decoder" => "entries"},
         _,
         path
       ) do
    assert name == @canonical
    verify_identity(identity, path <> "/segments/" <> name)
    <<1::32, n::16, name::binary, normalize_identity(identity)::binary>>
  end

  defp normalize_host_fields(payload, %{"decoder" => "info"}, native, path) do
    assert {:ok, facts} = Codec.info(payload)
    assert facts.os_pid == native.facts.os_pid
    assert facts.filesystem == native.facts.filesystem
    root = File.stat!(path)
    segments = File.stat!(path <> "/segments")
    assert facts.root == %{device: root.major_device, inode: root.inode}
    assert facts.segments == %{device: segments.major_device, inode: segments.inode}
    assert facts.ancestor_syncs >= 0
    <<_pid::64, writable, readable, _::binary>> = payload
    <<1::64, writable, readable, 2::64, 0::32, 3::64, 4::64, 5::64, 6::64>>
  end

  defp normalize_host_fields(<<free::64>>, %{"decoder" => "space"}, _, _) do
    assert free > 0
    <<1::64>>
  end

  defp normalize_host_fields(payload, _, _, _), do: payload

  defp only_stage(path) do
    [stage] = File.ls!(path <> "/segments")
    assert String.starts_with?(stage, ".tay-new-")
    stage
  end

  defp verify_identity(payload, path) do
    assert {:ok, identity, <<>>} = Codec.identity(payload, false)
    stat = File.stat!(path)

    assert identity == %{
             size: stat.size,
             device: stat.major_device,
             inode: stat.inode,
             links: stat.links,
             type: stat.type,
             mode: stat.mode
           }
  end

  defp normalize_identity(<<size::64, _device::64, _inode::64, rest::binary>>),
    do: <<size::64, 1::64, 2::64, rest::binary>>

  defp decode(%{"decoder" => "identity"}, payload) do
    case Codec.identity(payload, false) do
      {:ok, identity, <<>>} -> {:ok, identity}
      _ -> :error
    end
  end

  defp decode(%{"decoder" => "entries"}, <<count::32, payload::binary>>),
    do: Codec.entries(payload, count, [], false)

  defp decode(%{"decoder" => "entries"}, _), do: :error
  defp decode(%{"decoder" => "info"}, payload), do: Codec.info(payload)
  defp decode(%{"decoder" => "acquisition"}, payload), do: Codec.acquisition(payload)
  defp decode(%{"decoder" => "space"}, <<free::64>>), do: {:ok, free}
  defp decode(%{"decoder" => "space"}, _), do: :error
  defp decode(_, payload), do: {:ok, payload}

  defp expected_api(%{"operation" => "write"} = f, payload) do
    {:ok, identity} = decode(f, payload)
    {:ok, %{written: f["bytes_written"], identity: identity}}
  end

  defp expected_api(f, payload), do: decode(f, payload)

  defp invoke(native, %{"operation" => "read", "body" => hex}) do
    <<offset::64, length::32>> = bytes(hex)
    Native.read(native, offset, length)
  end

  defp invoke(native, %{"operation" => "open_read"}),
    do: Native.open_read(native, :segments, @canonical)

  defp invoke(native, %{"operation" => "list"}), do: Native.list(native, :segments)
  defp invoke(native, %{"operation" => "write"}), do: Native.write(native, 0, @file_bytes)

  defp invoke(native, %{"operation" => operation}),
    do: apply(Native, String.to_existing_atom(operation), [native])
end
