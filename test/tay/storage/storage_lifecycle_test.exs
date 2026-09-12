defmodule Tay.Storage.LifecycleTest do
  use ExUnit.Case, async: true
  alias Tay.Storage.{Writer, Native, Segment}
  import Tay.Test.NativeHelpers

  setup do
    Process.flag(:trap_exit, true)
    path = path()
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp start(path, opts \\ []),
    do:
      Writer.start_link(
        Keyword.merge([data_dir: path, durability: :write, test_helper: true], opts)
      )

  for boundary <- [
        :r0,
        :r1,
        {:r2, :synced},
        :r2,
        {:r3, :created},
        :r3,
        {:r4, :synced},
        :r4,
        :r5,
        :r6,
        :r7
      ] do
    @boundary boundary
    @expected_id if(boundary == :r0, do: 1, else: 2)
    @published boundary in [:r5, :r6, :r7]
    @stage_count if(boundary in [{:r3, :created}, :r3, {:r4, :synced}, :r4], do: 1, else: 0)
    test "helper crash after #{inspect(boundary)} preserves acknowledged prefix and deterministic restart",
         %{path: path} do
      boundary = @boundary

      hook = fn tag, native ->
        if tag == boundary do
          :ok = Native.fault(native, :check, 1, :crash_before)
          Native.check(native)
        else
          :ok
        end
      end

      {:ok, w} = start(path, on_transition: hook)
      assert {:ok, %{sequence: 1}} = Writer.append(w, 1, 1, "already acknowledged")
      file = Path.join([path, "segments", canonical(1)])
      prefix = File.read!(file)
      assert {:error, {:uncertain, _}} = Writer.rotate(w)
      assert Writer.status(w).state == :poisoned
      assert binary_part(File.read!(file), 0, byte_size(prefix)) == prefix
      staged = Path.wildcard(Path.join([path, "segments", ".tay-new-*.tmp"]), match_dot: true)
      staged_bytes = Map.new(staged, &{&1, File.read!(&1)})
      assert length(staged) == @stage_count
      expected = if @published, do: [canonical(1), canonical(2)], else: [canonical(1)]
      actual = File.ls!(Path.join(path, "segments")) -- Enum.map(staged, &Path.basename/1)
      assert Enum.sort(actual) == expected

      if @published,
        do: assert(File.stat!(Path.join([path, "segments", canonical(2)])).size == 44)

      GenServer.stop(w)
      assert {:ok, reopened} = start(path)
      assert Writer.status(reopened).segment.id == @expected_id
      assert Writer.status(reopened).next_sequence == 2
      assert {:ok, %{sequence: 2}} = Writer.append(reopened, 1, 1, "later acknowledged")
      for {name, bytes} <- staged_bytes, do: assert(File.read!(name) == bytes)
      GenServer.stop(reopened)
    end
  end

  for {boundary, operation} <- [
        {:r1, :sync},
        {{:r2, :synced}, :close_write},
        {:r2, :create_stage},
        {{:r3, :created}, :write},
        {:r3, :sync},
        {{:r4, :synced}, :close_write},
        {:r4, :publish},
        {:r5, :sync_dir},
        {:r6, :open_active}
      ] do
    @boundary boundary
    @operation operation
    test "I/O error in #{@operation} after #{inspect(boundary)} cannot acknowledge rotation", %{
      path: path
    } do
      boundary = @boundary
      operation = @operation

      hook = fn tag, n ->
        if tag == boundary, do: Native.fault(n, operation, 1, :error, 5), else: :ok
      end

      {:ok, w} = start(path, on_transition: hook)
      {:ok, _} = Writer.append(w, 1, 1, "retained")
      assert {:error, {:uncertain, _}} = Writer.rotate(w)
      assert {:error, {:poisoned, _}} = Writer.append(w, 1, 1, "forbidden")
      GenServer.stop(w)
      assert {:ok, w} = start(path)
      assert Writer.status(w).next_sequence == 2
      assert {:ok, [1]} = Writer.reduce(w, [], fn r, _, acc -> [r.sequence | acc] end)
      GenServer.stop(w)
    end
  end

  test "partial next header is only a staging file and remains after restart", %{path: path} do
    hook = fn
      {:r3, :created}, n -> Native.fault(n, :write, 1, :short, 28, 19)
      _, _ -> :ok
    end

    {:ok, w} = start(path, on_transition: hook)
    {:ok, _} = Writer.append(w, 1, 1, "retained")
    assert {:error, {:uncertain, %{bytes_written: 19}}} = Writer.rotate(w)
    [stage] = Path.wildcard(Path.join([path, "segments", ".tay-new-*.tmp"]), match_dot: true)
    assert File.stat!(stage).size == 19
    refute File.exists?(Path.join([path, "segments", canonical(2)]))
    GenServer.stop(w)
    {:ok, w} = start(path)
    assert File.stat!(stage).size == 19
    assert Writer.status(w).segment.id == 2
    GenServer.stop(w)
  end

  test "STORE publication race never replaces an existing marker", %{path: path} do
    hook = fn
      {:bootstrap_store, :close}, _ ->
        File.write!(Path.join(path, "STORE"), "operator file")
        :ok

      _, _ ->
        :ok
    end

    assert {:error, %{reason: "eexist"}} = start(path, on_transition: hook)
    assert File.read!(Path.join(path, "STORE")) == "operator file"
  end

  test "unsupported no-replace syscall cannot fall back to replacing publication", %{path: path} do
    # Native errno numbers differ between supported development platforms.
    errno = if :os.type() == {:unix, :darwin}, do: 78, else: 38

    hook = fn
      {:bootstrap_header, :close}, n -> Native.fault(n, :publish, 1, :error, errno)
      _, _ -> :ok
    end

    assert {:error, %{reason: "unsupported_syscall"}} = start(path, on_transition: hook)
    refute File.exists?(Path.join([path, "segments", canonical(1)]))
    refute File.exists?(Path.join(path, "STORE"))
    [stage] = Path.wildcard(Path.join([path, "segments", ".tay-new-*.tmp"]), match_dot: true)
    assert File.stat!(stage).size == 44
  end

  test "unsupported directory sync fails bootstrap before opening for appends", %{path: path} do
    errno = if :os.type() == {:unix, :darwin}, do: 45, else: 95

    hook = fn
      {:bootstrap_header, :publish}, n -> Native.fault(n, :sync_dir, 1, :error, errno)
      _, _ -> :ok
    end

    assert {:error, %{reason: "unsupported_capability"}} = start(path, on_transition: hook)
    assert File.stat!(Path.join([path, "segments", canonical(1)])).size == 44
    refute File.exists?(Path.join(path, "STORE"))
  end

  test "short genesis header requires explicit bootstrap and retains staging", %{path: path} do
    hook = fn
      {:bootstrap_header, :create}, n -> Native.fault(n, :write, 1, :short, 28, 9)
      _, _ -> :ok
    end

    assert {:error, %{bytes_written: 9}} = start(path, on_transition: hook)
    [stage] = Path.wildcard(Path.join([path, "segments", ".tay-new-*.tmp"]), match_dot: true)
    assert {:error, :explicit_bootstrap_required} = start(path)
    {:ok, w} = start(path, bootstrap: true)
    assert File.stat!(stage).size == 9
    GenServer.stop(w)
  end

  test "short STORE can complete only the proved header-only genesis", %{path: path} do
    hook = fn
      {:bootstrap_store, :create}, n -> Native.fault(n, :write, 1, :short, 28, 13)
      _, _ -> :ok
    end

    assert {:error, %{bytes_written: 13}} = start(path, on_transition: hook)
    [stage] = Path.wildcard(Path.join(path, ".tay-store-*.tmp"), match_dot: true)
    assert File.stat!(stage).size == 13
    {:ok, w} = start(path)
    assert File.stat!(stage).size == 13
    assert {:ok, _} = Segment.decode_store(File.read!(Path.join(path, "STORE")))
    GenServer.stop(w)
  end

  for errno <- [4, 5, 9, 13, 28] do
    @errno errno
    test "append errno #{errno} poisons without consuming or skipping a sequence", %{path: path} do
      {:ok, w} = start(path)
      :ok = Writer.inject_fault(w, :write, 1, :error, @errno)
      assert {:error, {:uncertain, %{bytes_written: 0}}} = Writer.append(w, 1, 1, "failed")
      assert Writer.status(w).next_sequence == 1
      GenServer.stop(w)
      {:ok, w} = start(path)
      assert {:ok, %{sequence: 1}} = Writer.append(w, 1, 1, "safe after full reinspection")
      GenServer.stop(w)
    end
  end
end
