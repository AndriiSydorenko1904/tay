defmodule Tay.RestoreTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Tay.Test.{EventHelpers, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R
  alias Tay.Test.EngineHelpers, as: E
  @script Path.expand("../../../scripts/tay_cold_copy.py", __DIR__)

  setup do
    Process.flag(:trap_exit, true)
    parent = NativeHelpers.path()
    File.mkdir_p!(parent)
    source = Path.join(parent, "source")
    frames = Enum.map(~w(E1 E2 E3 E4 E6 E5), &EventHelpers.fixture/1)

    R.store(source, [
      R.segment(1, 1, Enum.take(frames, 3), true),
      R.segment(2, 4, Enum.drop(frames, 3))
    ])

    on_exit(fn -> File.rm_rf!(parent) end)

    %{
      parent: parent,
      source: source,
      backup: Path.join(parent, "backup"),
      restored: Path.join(parent, "restored"),
      catalog: Path.join(parent, "backup.json")
    }
  end

  defp command(operation, source, target, catalog, extra \\ []) do
    mode =
      if System.get_env("TAY_TEST_SYNC") == "1",
        do: ["--durability", "sync", "--validated-filesystem"],
        else: ["--durability", "development"]

    System.cmd(
      System.find_executable("python3"),
      [@script, operation, source, target, "--catalog", catalog] ++ mode ++ extra,
      stderr_to_stdout: true
    )
  end

  defp inspect_store(path),
    do: R.after_release(fn -> Tay.Diagnostics.inspect(data_dir: path, durability: :write) end)

  test "complete cold backup and restore retain active history, stages and fresh semantic recovery",
       c do
    File.write!(
      Path.join(c.source, ".tay-store-" <> String.duplicate("a", 32) <> ".tmp"),
      <<1, 2>>
    )

    stage = ".tay-new-00000000000000000003-" <> String.duplicate("b", 32) <> ".tmp"
    File.write!(Path.join([c.source, "segments", stage]), <<1, 2, 3>>)
    before = R.snapshot(c.source)
    assert {result, 0} = command("backup", c.source, c.backup, c.catalog)
    assert result =~ "semantic_validation"
    assert File.read!(R.canonical(c.backup, 2)) == File.read!(R.canonical(c.source, 2))
    assert File.read!(Path.join([c.backup, "segments", stage])) == <<1, 2, 3>>
    assert R.snapshot(c.source) == before

    assert {_, 0} =
             command("restore", c.backup, c.restored, Path.join(c.parent, "restore.json"), [
               "--verify-catalog",
               c.catalog
             ])

    assert {:ok, %{record_count: 6, staging_count: 2, jobs: 1}} = inspect_store(c.restored)
    snapshot = R.snapshot(c.restored)
    assert {:ok, root} = E.restart(c.restored, __MODULE__, test_execution: false)

    assert {:ok, %{state: :cancelled}} =
             Tay.get_job(Tay.JobID.encode(EventHelpers.id()), name: __MODULE__)

    E.stop(root)
    assert R.snapshot(c.restored) == snapshot
  end

  test "a live source lock prevents copying and a destination is never overwritten", c do
    {:ok, native} = R.open(c.source)
    assert {message, 1} = command("backup", c.source, c.backup, c.catalog)
    assert message =~ "source_owned"
    refute File.exists?(c.backup)
    Tay.Storage.Native.shutdown(native)
    assert {:ok, _} = inspect_store(c.source)
    assert {_, 0} = command("backup", c.source, c.backup, c.catalog)
    snapshot = R.snapshot(c.backup)
    assert {_, 1} = command("backup", c.source, c.backup, Path.join(c.parent, "another.json"))
    assert R.snapshot(c.backup) == snapshot
  end

  for missing <- ["STORE", ".tay-owner.lock", "segments/00000000000000000002.tay"] do
    @missing missing
    test "restore rejects archive missing #{@missing} without silently accepting an older prefix",
         c do
      assert {_, 0} = command("backup", c.source, c.backup, c.catalog)
      File.rm!(Path.join(c.backup, @missing))
      before = R.snapshot(c.backup)

      assert {_, 1} =
               command("restore", c.backup, c.restored, Path.join(c.parent, "restore.json"), [
                 "--verify-catalog",
                 c.catalog
               ])

      refute File.exists?(c.restored)
      assert R.snapshot(c.backup) == before
    end
  end

  test "corrupt archive and untrusted path indirections preserve all failed evidence", c do
    assert {_, 0} = command("backup", c.source, c.backup, c.catalog)
    File.write!(R.canonical(c.backup, 2), <<0>>, [:append])
    before = R.snapshot(c.backup)

    assert {message, 1} =
             command("restore", c.backup, c.restored, Path.join(c.parent, "restore.json"), [
               "--verify-catalog",
               c.catalog
             ])

    assert message =~ "archive_checksum_mismatch"
    assert R.snapshot(c.backup) == before
    link = Path.join(c.parent, "source-link")
    File.ln_s!(c.source, link)
    assert {_, 1} = command("backup", link, c.restored, Path.join(c.parent, "link.json"))
    File.ln!(Path.join(c.source, "STORE"), Path.join(c.parent, "store-link"))

    assert {message, 1} =
             command("backup", c.source, c.restored, Path.join(c.parent, "hardlink.json"))

    assert message =~ "unsafe_file"
    refute File.exists?(c.restored)
  end

  test "an older valid backup has explicit RPO and cannot claim later acknowledged history", c do
    R.store(c.source, [R.segment(1, 1, [EventHelpers.fixture("E1")])])
    # R.store writes supplied files but intentionally never deletes others.
    File.rm!(R.canonical(c.source, 2))
    assert {_, 0} = command("backup", c.source, c.backup, c.catalog)
    File.write!(R.canonical(c.source, 1), EventHelpers.fixture("E2"), [:append])
    assert {:ok, %{record_count: 2}} = inspect_store(c.source)

    assert {_, 0} =
             command("restore", c.backup, c.restored, Path.join(c.parent, "restore.json"), [
               "--verify-catalog",
               c.catalog
             ])

    assert {:ok, %{record_count: 1, states: %{scheduled: 1}}} = inspect_store(c.restored)
    assert File.read!(c.catalog) =~ "catalog_history_only"
  end

  for {type, schema} <- [{47, 1}, {1, 2}] do
    @type_id type
    @schema schema
    test "copied unknown capability #{@type_id}/#{@schema} stops semantic inspection before activation",
         c do
      {:ok, frame} =
        Tay.Storage.Record.encode(%Tay.Storage.Record{
          sequence: 1,
          record_type: @type_id,
          payload_schema_version: @schema,
          payload: <<>>
        })

      R.store(c.source, [R.segment(1, 1, [frame], true)])
      File.rm!(R.canonical(c.source, 2))
      assert {_, 0} = command("backup", c.source, c.backup, c.catalog)

      assert {_, 0} =
               command("restore", c.backup, c.restored, Path.join(c.parent, "restore.json"), [
                 "--verify-catalog",
                 c.catalog
               ])

      before = R.snapshot(c.restored)
      assert {:error, %{kind: :unsupported_semantics}} = inspect_store(c.restored)
      assert R.snapshot(c.restored) == before
      refute File.exists?(R.canonical(c.restored, 2))
    end
  end

  test "restore requires an external catalog and rejects lowered resource budgets before publication",
       c do
    assert {_, 1} = command("restore", c.source, c.restored, c.catalog)
    assert {_, 1} = command("backup", c.source, c.backup, c.catalog, ["--max-files", "1"])
    assert {_, 1} = command("backup", c.source, c.backup, c.catalog, ["--max-bytes", "1"])
    assert {_, 1} = command("backup", c.source, c.backup, Path.join(c.source, "catalog.json"))
    refute File.exists?(c.backup)
  end

  test "inventory stops incrementally at the shared entry budget, including directory entries",
       c do
    script = """
    import os, runpy, sys
    from contextlib import ExitStack
    module = runpy.run_path(sys.argv[1])
    original = os.scandir
    observed = []
    class Bounded:
        def __init__(self, fd): self.iterator = original(fd)
        def __enter__(self): return self
        def __exit__(self, *args): self.iterator.close()
        def __iter__(self): return self
        def __next__(self):
            entry = next(self.iterator)
            observed.append(entry.name)
            assert len(observed) <= 5, 'must not enumerate after budget failure'
            return entry
    os.scandir = Bounded
    def forbidden(*args): raise AssertionError('unbounded listdir must not be used')
    os.listdir = forbidden
    with ExitStack() as stack:
        root, _ = module['directory'](stack, sys.argv[2])
        segments, _ = module['directory'](stack, sys.argv[2] + '/segments')
        try:
            module['inventory'](root, segments, 4, 10737418240)
            raise AssertionError('five entries exceed four-entry budget')
        except module['Refused'] as error:
            assert str(error) == 'file_budget'
            assert len(observed) == 5 and 'segments' in observed
    print('INCREMENTAL_BUDGET_VERIFIED')
    """

    assert {"INCREMENTAL_BUDGET_VERIFIED\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, @script, c.source],
               stderr_to_stdout: true
             )
  end

  for external <- ["destination", "catalog", "verify_catalog"] do
    @external external
    test "#{@external} pinned source inode aliases are refused before any destination write", c do
      # A pinned source FD under a distinct spelling models a bind-mount alias
      # without requiring privileged mount operations on the development host.
      script = """
      import os, runpy, sys, types
      module = runpy.run_path(sys.argv[1])
      copy = module['copy']
      original = copy.__globals__['directory']
      alias_parent = sys.argv[5] + '/alias'
      def alias(stack, path):
          return original(stack, sys.argv[2] + '/segments' if path == alias_parent else path)
      copy.__globals__['directory'] = alias
      args = types.SimpleNamespace(operation='backup', source=sys.argv[2], destination=sys.argv[3], catalog=sys.argv[4], verify_catalog=None, durability='development', validated_filesystem=False, max_files=100000, max_bytes=10737418240)
      setattr(args, sys.argv[6], alias_parent + '/outside-by-spelling')
      try:
          copy(args)
          raise AssertionError('source alias must be refused')
      except module['Refused'] as error:
          assert str(error) == 'source_directory_alias', str(error)
          print('SOURCE_ALIAS_REFUSED')
      """

      before = R.snapshot(c.source)

      assert {"SOURCE_ALIAS_REFUSED\n", 0} =
               System.cmd(
                 System.find_executable("python3"),
                 ["-c", script, @script, c.source, c.backup, c.catalog, c.parent, @external],
                 stderr_to_stdout: true
               )

      refute File.exists?(c.backup)
      refute File.exists?(c.catalog)
      assert R.snapshot(c.source) == before
      refute Enum.any?(File.ls!(c.parent), &String.contains?(&1, ".tay-copy-"))
    end
  end

  test "a FIFO replacement cannot block regular-file validation", c do
    script = """
    import os, runpy, signal, sys
    from contextlib import ExitStack
    module = runpy.run_path(sys.argv[1])
    os.mkfifo(sys.argv[2] + '/fifo')
    signal.alarm(3)
    with ExitStack() as stack:
        parent, _ = module['directory'](stack, sys.argv[2])
        try:
            module['regular'](stack, parent, 'fifo')
            raise AssertionError('FIFO must not be treated as a regular file')
        except module['Refused'] as error:
            assert str(error) == 'unsafe_file'
    print('FIFO_REFUSED_WITHOUT_BLOCKING')
    """

    assert {"FIFO_REFUSED_WITHOUT_BLOCKING\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, @script, c.parent],
               stderr_to_stdout: true
             )
  end

  test "a growing source or catalog cannot exceed its inspected byte budget" do
    script = """
    import os, runpy, sys
    module = runpy.run_path(sys.argv[1])
    requested = []
    def growing(fd, count):
        requested.append(count)
        assert len(requested) == 1, 'must stop after the first excess byte'
        return b'x' * count
    os.read = growing
    try:
        list(module['file_chunks'](123, 4))
        raise AssertionError('a growing file must be refused')
    except module['Refused'] as error:
        assert str(error) == 'source_changed'
        assert requested == [5]
    print('GROWTH_BOUNDED')
    """

    assert {"GROWTH_BOUNDED\n", 0} =
             System.cmd(System.find_executable("python3"), ["-c", script, @script],
               stderr_to_stdout: true
             )
  end

  test "exclusive publication preserves a destination created concurrently and failed staging evidence",
       c do
    script = """
    import os, runpy, sys, types
    module = runpy.run_path(sys.argv[1])
    copy = module['copy']
    original = copy.__globals__['no_replace']
    def race(parent, source, destination):
        os.mkdir(destination, dir_fd=parent)
        target = os.open(destination, os.O_RDONLY | os.O_DIRECTORY, dir_fd=parent)
        fd = os.open('operator-evidence', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=target)
        os.write(fd, b'preserved')
        os.close(fd)
        os.close(target)
        original(parent, source, destination)
    copy.__globals__['no_replace'] = race
    args = types.SimpleNamespace(operation='backup', source=sys.argv[2], destination=sys.argv[3], catalog=sys.argv[4], verify_catalog=None, durability='development', validated_filesystem=False, max_files=100000, max_bytes=10737418240)
    try:
        copy(args)
        raise AssertionError('publication must refuse')
    except module['Refused'] as error:
        assert str(error) == 'exclusive_publication_failed'
        print('RACE_PRESERVED')
    """

    before = R.snapshot(c.source)

    assert {"RACE_PRESERVED\n", 0} =
             System.cmd(
               System.find_executable("python3"),
               ["-c", script, @script, c.source, c.backup, c.catalog],
               stderr_to_stdout: true
             )

    assert File.read!(Path.join(c.backup, "operator-evidence")) == "preserved"
    assert Enum.count(File.ls!(c.parent), &String.starts_with?(&1, ".backup.tay-copy-")) == 1
    refute File.exists?(c.catalog)
    assert R.snapshot(c.source) == before
  end

  @tag skip: System.get_env("TAY_TEST_SYNC") != "1"
  test "Linux restore barriers cover every copied file then directories, publication and ancestors",
       c do
    script = """
    import os, runpy, stat, sys, types
    module = runpy.run_path(sys.argv[1])
    original = os.fsync
    calls = []
    def trace(fd):
        calls.append(('file' if stat.S_ISREG(os.fstat(fd).st_mode) else 'directory', os.readlink('/proc/self/fd/' + str(fd))))
        original(fd)
    os.fsync = trace
    args = types.SimpleNamespace(operation='backup', source=sys.argv[2], destination=sys.argv[3], catalog=sys.argv[4], verify_catalog=None, durability='sync', validated_filesystem=True, max_files=100000, max_bytes=10737418240)
    result = module['copy'](args)
    count = result['files']
    assert result['files_synced'] == count
    assert all(kind == 'file' for kind, _ in calls[:count])
    assert calls[count][0] == 'directory' and calls[count][1].endswith('/segments')
    assert calls[count+1][0] == 'directory' and '.tay-copy-' in calls[count+1][1]
    file_calls = [path for kind, path in calls if kind == 'file']
    assert len(file_calls) == count + 1 and file_calls[-1] == sys.argv[4]
    assert any(kind == 'directory' and path == '/' for kind, path in calls)
    print('SYNC_ORDER_VERIFIED')
    """

    assert {"SYNC_ORDER_VERIFIED\n", 0} =
             System.cmd(
               System.find_executable("python3"),
               ["-c", script, @script, c.source, c.backup, c.catalog],
               stderr_to_stdout: true
             )

    assert {:ok, %{record_count: 6}} = inspect_store(c.backup)
  end

  @tag skip: System.get_env("TAY_TEST_SYNC") != "1"
  test "a restored file sync failure never publishes or deletes partial evidence", c do
    script = """
    import os, runpy, sys, types
    module = runpy.run_path(sys.argv[1])
    original = os.fsync
    count = 0
    def fail(fd):
        global count
        count += 1
        if count == 3:
            raise OSError(5, 'injected file sync failure')
        original(fd)
    os.fsync = fail
    args = types.SimpleNamespace(operation='backup', source=sys.argv[2], destination=sys.argv[3], catalog=sys.argv[4], verify_catalog=None, durability='sync', validated_filesystem=True, max_files=100000, max_bytes=10737418240)
    try:
        module['copy'](args)
        raise AssertionError('sync must fail')
    except OSError:
        print('SYNC_FAILURE_PRESERVED')
    """

    before = R.snapshot(c.source)

    assert {"SYNC_FAILURE_PRESERVED\n", 0} =
             System.cmd(
               System.find_executable("python3"),
               ["-c", script, @script, c.source, c.backup, c.catalog],
               stderr_to_stdout: true
             )

    refute File.exists?(c.backup)
    refute File.exists?(c.catalog)
    assert Enum.count(File.ls!(c.parent), &String.starts_with?(&1, ".backup.tay-copy-")) == 1
    assert R.snapshot(c.source) == before
  end
end
