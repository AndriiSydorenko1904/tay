defmodule Tay.Storage.RecoveryLifecycleTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Native, Recovery, Writer}
  import Tay.Test.RecoveryHelpers

  setup do
    Process.flag(:trap_exit, true)
    path = Tay.Test.NativeHelpers.path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  for action <- [:crash_before, :crash_after, :drop_reply, :invalid_reply] do
    @action action
    test "existing acquisition #{@action} preserves namespace and eventually releases ownership",
         %{
           path: path
         } do
      store(path)
      before = snapshot(path)
      hook = fn native -> Native.fault(native, :acquire_existing, 1, @action) end
      timeout = if @action == :drop_reply, do: 2_000, else: 10_000

      assert {:error, _} = open(path, timeout: timeout, test_before_acquire: hook)
      assert snapshot(path) == before
      {:ok, native} = after_release(fn -> open(path) end)
      Native.shutdown(native)
      assert snapshot(path) == before
    end
  end

  for {operation, occurrence, action} <- [
        {:list, 1, :error},
        {:open_read, 1, :error},
        {:read, 1, :error},
        {:read, 2, :short},
        {:read, 3, :error},
        {:read, 4, :error},
        {:close_read, 1, :error},
        {:read, 1, :crash_before},
        {:read, 1, :crash_after},
        {:read, 1, :invalid_reply},
        {:read, 1, :drop_reply}
      ] do
    @operation operation
    @occurrence occurrence
    @action action
    test "preflight #{@operation}/#{occurrence}/#{action} preserves complete evidence", %{
      path: path
    } do
      store(path, [segment(1, 1, [frame(1)], true)])
      before = snapshot(path)

      hook = fn :recovery_acquired, native ->
        Native.fault(native, @operation, @occurrence, @action)
      end

      timeout = if @action == :drop_reply, do: 2_000, else: 10_000

      assert {:error, %{mutation: :none}} =
               start(path, spec(io_timeout_ms: timeout), on_transition: hook)

      assert snapshot(path) == before
      {:ok, writer} = after_release(fn -> start(path) end)
      assert {:ok, _, [{1, 1}]} = activate(writer)
      GenServer.stop(writer)
    end
  end

  for operation <- [:promotion_ancestor, :promotion_lock, :promotion_root, :promotion_segments] do
    for action <- [:error, :crash_before, :crash_after, :drop_reply] do
      @operation operation
      @action action
      test "#{operation}/#{action} blocks activation without publishing a successor", %{
        path: path
      } do
        store(path, [segment(1, 1, [frame(1)], true)])
        before = snapshot(path)
        timeout = if @action == :drop_reply, do: 2_000, else: 10_000
        {:ok, writer} = start(path, spec(io_timeout_ms: timeout))
        :ok = Writer.inject_fault(writer, @operation, 1, @action)

        assert {:error, %{kind: :uncertain_activation, mutation: :activation_uncertain}} =
                 activate(writer)

        assert snapshot(path) == before
        assert Writer.status(writer).state == :poisoned
        GenServer.stop(writer)
      end
    end
  end

  for boundary <- [{:r3, :created}, :r3, {:r4, :synced}, :r4, :r5, :r6, :r7] do
    @boundary boundary
    test "highest-sealed activation crash after #{inspect(boundary)} retains stages and history",
         %{path: path} do
      store(path, [segment(1, 1, [frame(1, 9)], true)])
      original = File.read!(canonical(path, 1))

      hook = fn tag, native ->
        if tag == @boundary do
          Native.fault(native, :check, 1, :crash_before)
          Native.check(native)
        else
          :ok
        end
      end

      {:ok, writer} = start(path, spec(), on_transition: hook)
      assert {:error, %{kind: :uncertain_activation}} = activate(writer)
      GenServer.stop(writer)
      assert File.read!(canonical(path, 1)) == original

      stages =
        File.ls!(Path.join(path, "segments"))
        |> Enum.filter(&String.starts_with?(&1, ".tay-new-"))

      retained =
        Map.new(stages, fn name -> {name, File.read!(Path.join([path, "segments", name]))} end)

      {:ok, writer} = after_release(fn -> start(path) end)
      assert {:ok, _, [{1, 9}]} = activate(writer)

      for {name, bytes} <- retained,
          do: assert(File.read!(Path.join([path, "segments", name])) == bytes)

      assert File.read!(canonical(path, 1)) == original
      GenServer.stop(writer)
    end
  end

  test "semantic rejection plus failed close keeps primary diagnosis and poisons connection", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1, 1, record_type: 49)])])
    before = snapshot(path)
    {:ok, native} = open(path)
    # STORE and physical segment close first; semantic traversal closes third.
    :ok = Native.fault(native, :close_read, 3, :error)

    assert {:error,
            %{kind: :unsupported_semantics, reason: :unknown_event_type, cleanup_error: cleanup}} =
             Recovery.replay(native, Tay.Test.RecoveryDecoder, [], &collect/3)

    assert cleanup.operation == :close_read
    assert {:error, %{kind: :uncertain}} = Native.info(native)
    assert snapshot(path) == before
  end

  test "continuous ownership excludes an independent BEAM before and after activation", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1)])])
    {:ok, writer} = start(path)
    pid = Writer.status(writer).os_pid

    script =
      "{:error, %{reason: \"store_busy\"}} = Tay.Storage.Native.open_existing(hd(System.argv()), durability: :write); IO.puts(\"busy\")"

    assert {"busy\n", 0} = Tay.Test.NativeHelpers.child_elixir(script, [path])
    {:ok, _, _} = activate(writer)
    assert Writer.status(writer).os_pid == pid
    assert {"busy\n", 0} = Tay.Test.NativeHelpers.child_elixir(script, [path])
    GenServer.stop(writer)
  end

  test "dead/foreign session references cannot authorize a new owner", %{path: path} do
    store(path)
    {:ok, first} = start(path)
    reference = Writer.status(first).session_ref
    GenServer.stop(first)
    {:ok, second} = start(path)
    assert {:error, %{reason: :stale_session}} = Writer.activate_recovered(second, reference)
    assert {:ok, _, []} = activate(second)
    GenServer.stop(second)
  end

  test "activation-window expiry discards candidate and closes ownership without mutation", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1)])])
    before = snapshot(path)
    {:ok, writer} = start(path, spec(activation_window_ms: 1_000))
    monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, 5_000
    assert snapshot(path) == before
    {:ok, native} = open(path)
    Native.shutdown(native)
  end

  test "expired scan deadline is retryable without changing physical validity", %{path: path} do
    store(path, [segment(1, 1, [frame(1)])])
    before = snapshot(path)
    {:ok, native} = open(path)
    expired = %{native | deadline: System.monotonic_time(:millisecond) - 1}
    assert {:error, %{kind: :resource_limit, mutation: :none}} = Recovery.inspect(expired)
    assert {:ok, _} = Recovery.inspect(native)
    Native.shutdown(native)
    assert snapshot(path) == before
  end

  test "owner kill during semantic replay never publishes and independent restart replays all", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1), frame(2)])])
    before = snapshot(path)

    script =
      "Process.flag(:trap_exit, true); s = %{Tay.Test.RecoveryHelpers.spec() | reducer: fn _, _, _ -> System.halt(23) end}; Tay.Test.RecoveryHelpers.start(hd(System.argv()), s)"

    assert {"", 23} = Tay.Test.NativeHelpers.child_elixir(script, [path])
    assert snapshot(path) == before
    {:ok, writer} = after_release(fn -> start(path) end)
    assert {:ok, _, [{2, 1}, {1, 1}]} = activate(writer)
    GenServer.stop(writer)
  end

  test "post-promotion timeout is activation uncertainty, not a retryable budget refusal", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1)], true)])
    before = snapshot(path)
    {:ok, writer} = start(path, spec(io_timeout_ms: 2_000))
    :ok = Writer.inject_fault(writer, :enable_mutations, 1, :drop_reply)

    assert {:error, %{kind: :uncertain_activation, mutation: :activation_uncertain}} =
             activate(writer)

    assert snapshot(path) == before
    GenServer.stop(writer)
  end

  for operation <- [:read, :close_read, :check] do
    @operation operation
    test "Q5 #{@operation} failure never activates a retained candidate", %{path: path} do
      store(path, [segment(1, 1, [frame(1)], true)])
      before = snapshot(path)
      {:ok, writer} = start(path)
      :ok = Writer.inject_fault(writer, @operation, 1, :error)
      assert {:error, %{mutation: :none}} = activate(writer)
      assert snapshot(path) == before
      GenServer.stop(writer)
    end
  end

  for {tag, mutation} <- [
        {:recovery_revalidating, :none},
        {:recovery_promoted, :activation_uncertain}
      ] do
    @tagpoint tag
    @mutation mutation
    test "activation deadline at #{tag} retains its correct mutation classification", %{
      path: path
    } do
      store(path, [segment(1, 1, [frame(1)], true)])
      before = snapshot(path)

      hook = fn tag, _ ->
        if tag == @tagpoint do
          Process.send_after(self(), :release_expired_deadline, 600)

          receive do
            :release_expired_deadline -> :ok
          end
        else
          :ok
        end
      end

      {:ok, writer} = start(path, spec(activation_deadline_ms: 500), on_transition: hook)
      assert {:error, error} = activate(writer)
      assert error.mutation == @mutation

      assert error.kind ==
               if(@mutation == :none, do: :resource_limit, else: :uncertain_activation)

      assert snapshot(path) == before
      GenServer.stop(writer)
    end
  end

  test "startup deadline covers acquisition and replay, not only per-read work", %{path: path} do
    store(path, [segment(1, 1, [frame(1)])])
    before = snapshot(path)

    hook = fn :recovery_acquired, _ ->
      Process.send_after(self(), :release_expired_deadline, 600)

      receive do
        :release_expired_deadline -> :ok
      end
    end

    assert {:error, %{kind: :resource_limit, mutation: :none}} =
             start(path, spec(deadline_ms: 500), on_transition: hook)

    assert snapshot(path) == before
  end

  test "a raw mutation queued during initialization cannot execute after replay", %{path: path} do
    store(path, [segment(1, 1, [frame(1)])])
    before = snapshot(path)
    parent = self()

    creator =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        hook = fn
          :recovery_acquired, _ ->
            send(parent, {:initializing, self()})

            receive do
              :continue_recovery -> :ok
            end

          _, _ ->
            :ok
        end

        {:ok, writer} = start(path, spec(), on_transition: hook)
        send(parent, {:ready_for_activation, writer})

        receive do
          :finish_owner_test -> GenServer.stop(writer)
        end
      end)

    assert_receive {:initializing, writer}, 5_000
    request = make_ref()
    send(writer, {:"$gen_call", {self(), request}, {:append, 47, 3, <<9>>}})
    send(writer, :continue_recovery)
    assert_receive {:ready_for_activation, ^writer}, 5_000
    assert_receive {^request, {:error, :admission_reference_required}}, 5_000
    assert snapshot(path) == before
    assert {:ok, _, [{1, 1}]} = activate(writer)
    send(creator.pid, :finish_owner_test)
    Task.await(creator)
  end

  test "complete append after lost helper reply occupies its sequence on recovery", %{path: path} do
    store(path, [segment(1, 1, [frame(1)])])
    {:ok, writer} = start(path, spec(), timeout: 2_000)
    {:ok, summary, _} = activate(writer)
    :ok = Writer.inject_fault(writer, :write, 1, :drop_reply)
    assert {:error, {:uncertain, _}} = Writer.append(writer, summary.admission_ref, 47, 3, <<2>>)
    GenServer.stop(writer)
    {:ok, writer} = after_release(fn -> start(path) end)
    assert {:ok, %{next_sequence: 3}, [{2, 2}, {1, 1}]} = activate(writer)
    GenServer.stop(writer)
  end

  test "partial footer written by the native helper can never regain writable activation", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1)])])
    {:ok, writer} = start(path)
    {:ok, summary, _} = activate(writer)
    :ok = Writer.inject_fault(writer, :write, 1, :short, 28, 20)
    assert {:error, {:uncertain, _}} = Writer.seal(writer, summary.admission_ref)
    GenServer.stop(writer)
    before = snapshot(path)

    for _ <- 1..2 do
      assert {:error, %{kind: :incomplete_tail, mutation: :none}} =
               after_release(fn -> start(path) end)

      assert snapshot(path) == before
    end
  end

  for occurrence <- [1, 2] do
    @occurrence occurrence
    test "activation existing-file sync #{@occurrence} failure prevents readiness", %{path: path} do
      store(path, [segment(1, 1, [frame(1)])])
      before = snapshot(path)
      {:ok, writer} = start(path)
      :ok = Writer.inject_fault(writer, :sync_read, @occurrence, :error)
      assert {:error, %{kind: :uncertain_activation}} = activate(writer)
      assert snapshot(path) == before
      GenServer.stop(writer)
    end
  end

  @tag :linux_sync
  @tag skip: :os.type() != {:unix, :linux} or System.get_env("TAY_TEST_SYNC") != "1"
  test "strict recovered activation and complete failed-sync append survive independent restart",
       %{path: path} do
    store(path, [segment(1, 1, [frame(1)], true)])
    {:ok, writer} = start(path, spec(), durability: :sync, validated_filesystem: true)
    assert {:ok, summary, [{1, 1}]} = activate(writer)
    :ok = Writer.inject_fault(writer, :sync, 1, :error)
    assert {:error, {:uncertain, _}} = Writer.append(writer, summary.admission_ref, 47, 3, <<2>>)
    GenServer.stop(writer)

    {:ok, writer} =
      after_release(fn -> start(path, spec(), durability: :sync, validated_filesystem: true) end)

    assert {:ok, %{next_sequence: 3}, [{2, 2}, {1, 1}]} = activate(writer)
    GenServer.stop(writer)
  end

  @tag :linux_sync
  @tag skip: :os.type() != {:unix, :linux} or System.get_env("TAY_TEST_SYNC") != "1"
  test "strict recovered-session acknowledgement survives an abrupt independent BEAM exit", %{
    path: path
  } do
    store(path, [segment(1, 1, [frame(1)], true)])

    script =
      "{:ok, w} = Tay.Test.RecoveryHelpers.start(hd(System.argv()), Tay.Test.RecoveryHelpers.spec(), durability: :sync, validated_filesystem: true); {:ok, s, _} = Tay.Test.RecoveryHelpers.activate(w); {:ok, %{sequence: 2, durability: :sync}} = Tay.Storage.Writer.append(w, s.admission_ref, 47, 3, <<42>>); IO.puts(\"synced\"); System.halt(23)"

    assert {"synced\n", 23} = Tay.Test.NativeHelpers.child_elixir(script, [path])

    {:ok, writer} =
      after_release(fn -> start(path, spec(), durability: :sync, validated_filesystem: true) end)

    assert {:ok, _, [{2, 42}, {1, 1}]} = activate(writer)
    GenServer.stop(writer)
  end
end
