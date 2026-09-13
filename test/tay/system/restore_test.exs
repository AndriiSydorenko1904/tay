defmodule Tay.RestoreTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Tay.Storage.ColdCopy
  alias Tay.Test.{EventHelpers, NativeHelpers}
  alias Tay.Test.EngineHelpers, as: E
  alias Tay.Test.RecoveryHelpers, as: R

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

  defp copy(operation, source, destination, catalog, extra \\ []) do
    options =
      [
        source: source,
        destination: destination,
        catalog: catalog,
        durability: :development,
        max_files: 100_000,
        max_bytes: 10_737_418_240
      ] ++ extra

    apply(ColdCopy, operation, [options])
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

    assert {:ok, %{semantic_validation: "required"}} =
             copy(:backup, c.source, c.backup, c.catalog)

    assert File.read!(R.canonical(c.backup, 2)) == File.read!(R.canonical(c.source, 2))
    assert File.read!(Path.join([c.backup, "segments", stage])) == <<1, 2, 3>>
    assert R.snapshot(c.source) == before

    assert {:ok, _} =
             copy(:restore, c.backup, c.restored, Path.join(c.parent, "restore.json"),
               verify_catalog: c.catalog
             )

    assert {:ok, %{record_count: 6, staging_count: 2, jobs: 1}} = inspect_store(c.restored)
    snapshot = R.snapshot(c.restored)
    assert {:ok, root} = E.restart(c.restored, __MODULE__, test_execution: false)

    assert {:ok, %{state: :cancelled}} =
             Tay.get_job(Tay.JobID.encode(EventHelpers.id()), name: __MODULE__)

    E.stop(root)
    assert R.snapshot(c.restored) == snapshot
  end

  test "an older valid backup has explicit RPO and cannot claim later acknowledged history", c do
    R.store(c.source, [R.segment(1, 1, [EventHelpers.fixture("E1")])])
    File.rm!(R.canonical(c.source, 2))
    assert {:ok, _} = copy(:backup, c.source, c.backup, c.catalog)
    File.write!(R.canonical(c.source, 1), EventHelpers.fixture("E2"), [:append])
    assert {:ok, %{record_count: 2}} = inspect_store(c.source)

    assert {:ok, _} =
             copy(:restore, c.backup, c.restored, Path.join(c.parent, "restore.json"),
               verify_catalog: c.catalog
             )

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
      assert {:ok, _} = copy(:backup, c.source, c.backup, c.catalog)

      assert {:ok, _} =
               copy(:restore, c.backup, c.restored, Path.join(c.parent, "restore.json"),
                 verify_catalog: c.catalog
               )

      before = R.snapshot(c.restored)
      assert {:error, %{kind: :unsupported_semantics}} = inspect_store(c.restored)
      assert R.snapshot(c.restored) == before
      refute File.exists?(R.canonical(c.restored, 2))
    end
  end
end
