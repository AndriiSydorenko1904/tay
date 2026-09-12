defmodule Tay.Storage.RecoverySemanticsTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Native, Recovery}
  import Tay.Test.RecoveryHelpers

  setup do
    Process.flag(:trap_exit, true)
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  for {fields, kind, reason} <- [
        {[record_type: 49], :unsupported_semantics, :unknown_event_type},
        {[payload_schema_version: 4], :unsupported_semantics, :unsupported_payload_schema},
        {[payload: <<2, 3>>], :invalid_payload, :invalid_test_payload}
      ] do
    @fields fields
    @kind kind
    @reason reason
    test "A/B/C stops at B: #{reason}", %{path: path} do
      store(path, [segment(1, 1, [frame(1, 1), frame(2, 2, @fields), frame(3, 3)], true)])
      before = snapshot(path)
      parent = self()

      hook = fn :recovery_acquired, _ ->
        Process.put(:recovery_test_observer, parent)
        :ok
      end

      replay = %{
        spec()
        | codec: Tay.Test.RecoveryProbeDecoder,
          reducer: fn event, position, acc ->
            send(parent, {:reduced, position.sequence})
            collect(event, position, acc)
          end
      }

      assert {:error, error} = start(path, replay, on_transition: hook)
      assert error.kind == @kind
      assert error.reason == @reason
      assert error.sequence == 2
      assert error.offset == 73
      assert error.action == :preserve_and_stop
      assert error.mutation == :none
      assert_receive {:reduced, 1}
      refute_receive {:reduced, 2}
      refute_receive {:reduced, 3}
      refute_receive {:decode, <<3>>}
      assert snapshot(path) == before
    end
  end

  test "late physical damage takes precedence over unknown early semantics", %{path: path} do
    damaged = Tay.Test.RecordHelpers.flip(frame(2), 28, 0)
    store(path, [segment(1, 1, [frame(1, 1, record_type: 49), damaged])])
    before = snapshot(path)
    {:ok, native} = open(path)
    Process.put(:recovery_test_observer, self())

    assert {:error, %{stage: :preflight, kind: :physical_corruption}} =
             Recovery.replay(native, Tay.Test.RecoveryProbeDecoder, [], &collect/3)

    refute_receive {:known, _}
    Native.shutdown(native)
    assert snapshot(path) == before
  end

  test "decoder consumption, contracts and failures cannot publish a prefix or leak secrets", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1), frame(2)])])
    before = snapshot(path)

    for {fun, kind} <- [
          {fn _, _, _, _ -> {:ok, :event, 0} end, :invalid_payload},
          {fn _, _, _, _ -> {:ok, :event, 2} end, :invalid_payload},
          {fn _, _, _, _ -> {:ok, :event, 1.0} end, :invalid_payload},
          {fn _, _, _, _ -> :skip end, :callback},
          {fn _, _, _, _ -> raise "private payload secret" end, :callback},
          {fn _, _, _, _ -> throw("private payload secret") end, :callback},
          {fn _, _, _, _ -> exit("private payload secret") end, :callback},
          {fn _, _, _, _ -> {:error, "private payload secret"} end, :invalid_payload}
        ] do
      {:ok, native} = open(path)
      Process.put(:recovery_test_decoder, fun)

      assert {:error, error} =
               Recovery.replay(native, Tay.Test.RecoveryProbeDecoder, [], &collect/3)

      assert error.kind == kind
      refute inspect(error) =~ "private payload secret"
      assert {:ok, %{readable: false}} = Native.info(native)
      Native.shutdown(native)
      assert snapshot(path) == before
    end
  end

  test "invalid capability return and late consumer rejection fail explicitly", %{path: path} do
    store(path, [segment(1, 1, [frame(1), frame(2)])])
    {:ok, native} = open(path)
    Process.put(:recovery_test_known, fn _ -> :yes end)

    assert {:error, %{kind: :callback, reason: :invalid_capability_result}} =
             Recovery.replay(native, Tay.Test.RecoveryProbeDecoder, [], &collect/3)

    Process.delete(:recovery_test_known)

    assert {:error, %{kind: :consumer_rejected, sequence: 2}} =
             Recovery.replay(native, Tay.Test.RecoveryDecoder, [], fn event, position, acc ->
               if position.sequence == 2,
                 do: {:error, :test_transition_rejected},
                 else: collect(event, position, acc)
             end)

    assert {:ok, %{readable: false}} = Native.info(native)
    Native.shutdown(native)
  end

  test "complete events replay identically with success, lost reply or unknown external ACK", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1, 17), frame(2, 29)])])

    results =
      for _external_ack <- [:success, :lost_reply, :unknown] do
        {:ok, writer} = start(path)
        {:ok, summary, candidate} = activate(writer)
        GenServer.stop(writer)
        {summary.next_sequence, candidate}
      end

    assert Enum.uniq(results) == [{3, [{2, 29}, {1, 17}]}]
  end

  test "fresh independent BEAM requires no runtime worker module or atoms from payload", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1, 42)])])

    script =
      "Code.ensure_loaded!(Tay.Test.RecoveryDecoder); false = Code.ensure_loaded?(AbsentWorkerForRecovery); {:ok, w} = Tay.Test.RecoveryHelpers.start(hd(System.argv())); {:ok, s, [{1, 42}]} = Tay.Test.RecoveryHelpers.activate(w); IO.puts(s.next_sequence); GenServer.stop(w)"

    assert {"2\n", 0} = Tay.Test.NativeHelpers.child_elixir(script, [path])
  end
end
