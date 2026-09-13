defmodule Tay.Storage.ColdCopyTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Tay.Storage.ColdCopy
  alias Tay.Storage.Native
  alias Tay.Test.{EventHelpers, NativeHelpers}
  alias Tay.Test.RecoveryHelpers, as: R

  setup do
    parent = NativeHelpers.path()
    File.mkdir_p!(parent)
    source = Path.join(parent, "source")
    R.store(source, [R.segment(1, 1, [EventHelpers.fixture("E1")], true)])
    on_exit(fn -> File.rm_rf!(parent) end)

    %{
      parent: parent,
      source: source,
      backup: Path.join(parent, "backup"),
      catalog: Path.join(parent, "backup.json"),
      restored: Path.join(parent, "restored"),
      restored_catalog: Path.join(parent, "restored.json")
    }
  end

  defp options(source, destination, catalog, extra \\ []) do
    Keyword.merge(
      [
        source: source,
        destination: destination,
        catalog: catalog,
        durability: :development,
        validated_filesystem: false,
        max_files: 100_000,
        max_bytes: 10_737_418_240
      ],
      extra
    )
  end

  test "backs up and restores byte-identical complete store inventory with a SHA-256 catalog",
       c do
    assert {:ok, %{result: "development_copy", files: count, files_synced: 0}} =
             ColdCopy.backup(options(c.source, c.backup, c.catalog))

    assert count >= 3
    assert File.read!(Path.join(c.backup, "STORE")) == File.read!(Path.join(c.source, "STORE"))
    assert (File.stat!(c.backup).mode &&& 0o777) == 0o700
    assert (File.stat!(Path.join(c.backup, "STORE")).mode &&& 0o777) == 0o600

    source_segment = Path.join([c.source, "segments", "00000000000000000001.tay"])
    backup_segment = Path.join([c.backup, "segments", "00000000000000000001.tay"])
    assert File.read!(backup_segment) == File.read!(source_segment)

    catalog = :json.decode(File.read!(c.catalog))
    assert catalog["version"] == 1
    assert catalog["filesystem"] == :null

    assert catalog["files"]["segments/00000000000000000001.tay"]["sha256"] ==
             :crypto.hash(:sha256, File.read!(source_segment)) |> Base.encode16(case: :lower)

    assert {:ok, %{result: "development_copy"}} =
             ColdCopy.restore(
               options(c.backup, c.restored, c.restored_catalog, verify_catalog: c.catalog)
             )

    assert File.read!(Path.join([c.restored, "segments", "00000000000000000001.tay"])) ==
             File.read!(source_segment)
  end

  test "refuses a live owned source and leaves no destination", c do
    {:ok, owner} = R.open(c.source)
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)), :source_owned)
    refute File.exists?(c.backup)
    Tay.Storage.Native.shutdown(owner)
  end

  test "never overwrites an existing destination or catalog", c do
    File.mkdir!(c.backup)
    File.write!(Path.join(c.backup, "operator-evidence"), "keep")
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)), :destination_exists)
    assert File.read!(Path.join(c.backup, "operator-evidence")) == "keep"

    File.rm!(Path.join(c.backup, "operator-evidence"))
    File.rmdir!(c.backup)
    File.write!(c.catalog, "catalog-evidence")
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)))
    assert File.read!(c.catalog) == "catalog-evidence"
    refute File.exists?(c.backup)
  end

  test "refuses symlinked source paths and hard-linked source files", c do
    linked = Path.join(c.parent, "source-link")
    File.ln_s!(c.source, linked)
    assert refused(ColdCopy.backup(options(linked, c.backup, c.catalog)), :unsafe_path)

    File.ln!(Path.join(c.source, "STORE"), Path.join(c.parent, "store-alias"))
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)), :unsafe_file)
    refute File.exists?(c.backup)

    destination_link = Path.join(c.parent, "destination-link")
    File.ln_s!(c.source, destination_link)
    assert refused(ColdCopy.backup(options(c.source, destination_link, c.catalog)))
    refute File.exists?(c.catalog)
  end

  test "rejects regular files where source or destination directories are required", c do
    source_file = Path.join(c.parent, "source-file")
    File.write!(source_file, "ordinary file")
    assert refused(ColdCopy.backup(options(source_file, c.backup, c.catalog)))

    parent_file = Path.join(c.parent, "destination-parent-file")
    File.write!(parent_file, "operator-evidence")
    destination = Path.join(parent_file, "backup")
    assert refused(ColdCopy.backup(options(c.source, destination, c.catalog)))
    assert File.read!(parent_file) == "operator-evidence"
    refute File.exists?(c.catalog)
  end

  test "detects source changes after hashing, lock replacement, and while copying", c do
    change_after_hash = fn
      :after_hash ->
        File.write!(Path.join(c.source, "STORE"), "changed", [:append])
        :ok

      _ ->
        :ok
    end

    assert refused(
             ColdCopy.backup(
               options(c.source, c.backup, c.catalog, test_hook: change_after_hash)
             ),
             :source_changed
           )

    refute File.exists?(c.backup)

    R.store(c.source, [R.segment(1, 1, [EventHelpers.fixture("E1")], true)])

    replace_lock = fn
      :after_hash ->
        lock = Path.join(c.source, ".tay-owner.lock")
        File.rm!(lock)
        File.write!(lock, "replacement")
        :ok

      _ ->
        :ok
    end

    assert refused(
             ColdCopy.backup(options(c.source, c.backup, c.catalog, test_hook: replace_lock))
           )

    refute File.exists?(c.backup)

    R.store(c.source, [R.segment(1, 1, [EventHelpers.fixture("E1")], true)])
    payload = Path.join(c.source, "payload")
    File.write!(payload, :binary.copy(<<7>>, 1_100_000))

    mutate_during_copy = fn
      {:after_copy_chunk, "payload", _} ->
        File.write!(payload, <<8>>, [:append])
        :ok

      _ ->
        :ok
    end

    assert refused(
             ColdCopy.backup(
               options(c.source, c.backup, c.catalog, test_hook: mutate_during_copy)
             ),
             :source_changed
           )

    refute File.exists?(c.backup)
  end

  test "enforces inventory budgets and required store components", c do
    assert refused(
             ColdCopy.backup(options(c.source, c.backup, c.catalog, max_files: 1)),
             :file_budget
           )

    assert refused(
             ColdCopy.backup(options(c.source, c.backup, c.catalog, max_bytes: 1)),
             :byte_budget
           )

    File.rm!(Path.join(c.source, "STORE"))
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)), :missing_metadata)

    R.store(c.source, [R.segment(1, 1, [EventHelpers.fixture("E1")], true)])
    File.rm_rf!(Path.join(c.source, "segments"))
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)))
  end

  test "requires actual history and rejects unsafe inventory file types", c do
    File.rm!(Path.join([c.source, "segments", "00000000000000000001.tay"]))
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)), :missing_history)

    R.store(c.source, [R.segment(1, 1, [EventHelpers.fixture("E1")], true)])
    File.ln_s!(Path.join(c.source, "STORE"), Path.join(c.source, "indirection"))
    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog)), :unsafe_file)
    refute File.exists?(c.backup)
  end

  test "sync requires explicit filesystem validation and development mode remains available", c do
    assert refused(
             ColdCopy.backup(
               options(c.source, c.backup, c.catalog,
                 durability: :sync,
                 validated_filesystem: false
               )
             ),
             :filesystem_validation_required
           )

    assert {:ok, %{result: "development_copy"}} =
             ColdCopy.cli_options(
               [
                 "--source",
                 c.source,
                 "--destination",
                 c.backup,
                 "--catalog",
                 c.catalog,
                 "--durability",
                 "development"
               ],
               :backup
             )
  end

  test "Mix backup and restore tasks run through the shared CLI contract", c do
    backup_output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Tay.Storage.Backup.run([
          "--source",
          c.source,
          "--destination",
          c.backup,
          "--catalog",
          c.catalog,
          "--durability",
          "development"
        ])
      end)

    assert :json.decode(String.trim(backup_output))["result"] == "development_copy"

    restore_output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Tay.Storage.Restore.run([
          "--source",
          c.backup,
          "--destination",
          c.restored,
          "--catalog",
          c.restored_catalog,
          "--verify-catalog",
          c.catalog,
          "--durability",
          "development"
        ])
      end)

    assert :json.decode(String.trim(restore_output))["result"] == "development_copy"
    assert File.read!(Path.join(c.restored, "STORE")) == File.read!(Path.join(c.source, "STORE"))
  end

  test "rejects overlap and catalogs inside either store", c do
    assert refused(
             ColdCopy.backup(options(c.source, Path.join(c.source, "backup"), c.catalog)),
             :overlapping_paths
           )

    assert refused(
             ColdCopy.backup(options(c.source, c.backup, Path.join(c.source, "catalog.json"))),
             :catalog_must_be_external
           )

    assert refused(
             ColdCopy.backup(options(c.source, c.backup, Path.join(c.backup, "catalog.json"))),
             :catalog_must_be_external
           )
  end

  test "restore requires and strictly verifies an external catalog", c do
    assert {:ok, _} = ColdCopy.backup(options(c.source, c.backup, c.catalog))

    assert refused(
             ColdCopy.restore(options(c.backup, c.restored, c.restored_catalog)),
             :restore_catalog_required
           )

    File.write!(c.catalog, "not json")

    assert refused(
             ColdCopy.restore(
               options(c.backup, c.restored, c.restored_catalog, verify_catalog: c.catalog)
             ),
             :invalid_catalog
           )

    assert {:ok, _} =
             ColdCopy.backup(
               options(c.source, Path.join(c.parent, "other"), Path.join(c.parent, "other.json"))
             )

    valid = Path.join(c.parent, "other.json")
    File.write!(Path.join(c.backup, "extra"), "unexpected")

    assert refused(
             ColdCopy.restore(
               options(c.backup, c.restored, c.restored_catalog, verify_catalog: valid)
             ),
             :archive_checksum_mismatch
           )
  end

  test "rejects well-formed catalogs with altered hashes or malformed file shapes", c do
    assert {:ok, _} = ColdCopy.backup(options(c.source, c.backup, c.catalog))
    original = :json.decode(File.read!(c.catalog))
    path = "segments/00000000000000000001.tay"
    files = put_in(original["files"][path]["sha256"], String.duplicate("0", 64))
    File.write!(c.catalog, :json.encode(files))

    assert refused(
             ColdCopy.restore(
               options(c.backup, c.restored, c.restored_catalog, verify_catalog: c.catalog)
             ),
             :archive_checksum_mismatch
           )

    File.write!(c.catalog, ~s({"version":1,"files":[]}))

    assert refused(
             ColdCopy.restore(
               options(c.backup, c.restored, c.restored_catalog, verify_catalog: c.catalog)
             ),
             :invalid_catalog
           )
  end

  test "refuses missing and corrupted archive files without overwriting evidence", c do
    assert {:ok, _} = ColdCopy.backup(options(c.source, c.backup, c.catalog))
    File.rm!(Path.join(c.backup, "STORE"))

    assert refused(
             ColdCopy.restore(
               options(c.backup, c.restored, c.restored_catalog, verify_catalog: c.catalog)
             )
           )

    refute File.exists?(c.restored)

    assert {:ok, _} =
             ColdCopy.backup(
               options(c.source, Path.join(c.parent, "copy"), Path.join(c.parent, "copy.json"))
             )

    corrupted = Path.join(c.parent, "copy")
    File.write!(Path.join([corrupted, "segments", "00000000000000000001.tay"]), <<0>>, [:append])

    assert refused(
             ColdCopy.restore(
               options(corrupted, c.restored, c.restored_catalog,
                 verify_catalog: Path.join(c.parent, "copy.json")
               )
             ),
             :archive_checksum_mismatch
           )
  end

  test "preserves partial staging and concurrent publication evidence", c do
    collide = fn
      :after_stage ->
        File.mkdir!(c.backup)
        File.write!(Path.join(c.backup, "operator-evidence"), "preserved")
        :ok

      _ ->
        :ok
    end

    assert refused(ColdCopy.backup(options(c.source, c.backup, c.catalog, test_hook: collide)))
    assert File.read!(Path.join(c.backup, "operator-evidence")) == "preserved"
    assert Enum.any?(File.ls!(c.parent), &String.starts_with?(&1, ".backup.tay-copy-"))
    refute File.exists?(c.catalog)
  end

  test "keeps the staged ownership lock held until publication", c do
    parent = self()

    inspect_stage = fn
      {:before_copy, "STORE"} ->
        [name] = Enum.filter(File.ls!(c.parent), &String.starts_with?(&1, ".backup.tay-copy-"))
        path = Path.join(c.parent, name)
        send(parent, {:stage_owner, Native.open_existing(path, durability: :write)})
        :ok

      _ ->
        :ok
    end

    assert {:ok, _} =
             ColdCopy.backup(options(c.source, c.backup, c.catalog, test_hook: inspect_stage))

    assert_receive {:stage_owner, {:error, %{reason: "store_busy"}}}
  end

  test "refuses a preexisting staging name without modifying it", c do
    {:ok, source} = R.open(c.source)
    {:ok, info} = Native.info(source)
    {:ok, target} = Native.open_cold_target(info, c.backup, c.catalog, nil, durability: :write)
    staging = ".backup.tay-copy-collision"
    stage_path = Path.join(c.parent, staging)
    File.mkdir!(stage_path)
    File.write!(Path.join(stage_path, "operator-evidence"), "preserved")

    assert {:error, %{reason: "eexist"}} = Native.cold_create_stage(target, staging)
    assert File.read!(Path.join(stage_path, "operator-evidence")) == "preserved"
    refute File.exists?(c.backup)
    Native.shutdown(target)
    Native.shutdown(source)
  end

  test "native target rejects a source-directory alias before staging", c do
    {:ok, source} = R.open(c.source)
    {:ok, info} = Native.info(source)
    destination = Path.join([c.source, "segments", "nested-backup"])

    assert {:error, %{reason: "ebusy"}} =
             Native.open_cold_target(info, destination, c.catalog, nil, durability: :write)

    refute File.exists?(destination)
    Native.shutdown(source)
  end

  test "revalidates destination ancestors and refuses symlink traversal", c do
    destination_parent = Path.join(c.parent, "destination-parent")
    moved_parent = Path.join(c.parent, "original-parent")
    File.mkdir!(destination_parent)
    destination = Path.join(destination_parent, "backup")

    replace_parent = fn
      :after_stage ->
        File.rename!(destination_parent, moved_parent)
        File.mkdir!(destination_parent)
        File.write!(Path.join(destination_parent, "operator-evidence"), "preserved")
        :ok

      _ ->
        :ok
    end

    assert refused(
             ColdCopy.backup(options(c.source, destination, c.catalog, test_hook: replace_parent))
           )

    assert File.read!(Path.join(destination_parent, "operator-evidence")) == "preserved"
    assert Enum.any?(File.ls!(moved_parent), &String.starts_with?(&1, ".backup.tay-copy-"))
    refute File.exists?(destination)
    refute File.exists?(c.catalog)

    symlink_parent = Path.join(c.parent, "symlink-parent")
    File.ln_s!(c.source, symlink_parent)

    assert refused(
             ColdCopy.backup(options(c.source, Path.join(symlink_parent, "backup"), c.catalog))
           )
  end

  test "propagates catalog publication permission failure and preserves the partial backup", c do
    catalog_parent = Path.join(c.parent, "read-only")
    File.mkdir!(catalog_parent)
    catalog = Path.join(catalog_parent, "backup.json")
    File.chmod!(catalog_parent, 0o500)

    result =
      try do
        ColdCopy.backup(options(c.source, c.backup, catalog))
      after
        File.chmod!(catalog_parent, 0o700)
      end

    assert refused(result)
    assert File.regular?(Path.join(c.backup, "STORE"))
    refute File.exists?(catalog)
  end

  defp refused({:error, %{result: "refused", reason: reason}}, expected \\ nil) do
    if expected, do: assert(reason == expected)
    true
  end
end
