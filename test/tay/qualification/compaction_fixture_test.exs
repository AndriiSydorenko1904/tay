defmodule Tay.Qualification.CompactionFixtureTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000

  test "cold fixtures survive repeated runs, expiration and checkpoint deltas" do
    root = Tay.Test.NativeHelpers.path()
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for profile <- ~w(bootstrap checkpoint mixed) do
      fixture = Path.join(root, profile)
      seed = ["--action", "seed", "--fixture", fixture, "--profile", profile, "--jobs", "20"]
      {_, 0} = command(seed)
      original = contents(fixture)

      for {suffix, options, after_count} <- [
            {"retain", [], 20},
            {"expire", ["--expire-terminal"], if(profile == "mixed", do: 2, else: 0)}
          ] do
        run = Path.join(root, profile <> "-" <> suffix)
        output = run <> ".json"

        {text, code} =
          command(
            ["--action", "run", "--fixture", fixture, "--path", run, "--output", output] ++
              options
          )

        assert code == 0, text
        report = output |> File.read!() |> JSON.decode!()
        assert report["benchmark"] == "tay-compaction-fixture-v1"
        assert report["measurement"]["jobs_before"] == 20
        assert report["measurement"]["jobs_after"] == after_count
        assert report["measurement"]["compaction_us"] > 0
        assert report["measurement"]["restore_us"] > 0
        assert File.dir?(Path.join(run, "store"))
        assert contents(fixture) == original
      end

      {_, code} = command(seed)
      assert code != 0
      assert contents(fixture) == original
    end

    fixture = Path.join(root, "checkpoint")
    original = contents(fixture)
    output = Path.join(root, "delta.json")

    {text, code} =
      command([
        "--action",
        "run",
        "--fixture",
        fixture,
        "--path",
        Path.join(root, "delta"),
        "--output",
        output,
        "--delta-jobs",
        "1"
      ])

    assert code == 0, text
    report = output |> File.read!() |> JSON.decode!()
    assert report["measurement"]["jobs_before"] == 21
    assert report["measurement"]["jobs_after"] == 21
    assert report["measurement"]["stats"]["reused_bytes"] > 0
    assert contents(fixture) == original

    {_, code} =
      command([
        "--action",
        "run",
        "--fixture",
        fixture,
        "--path",
        Path.join(fixture, "nested"),
        "--output",
        Path.join(root, "nested.json")
      ])

    assert code != 0
    refute File.exists?(Path.join(fixture, "nested"))

    File.write!(Path.join(fixture, "catalog.json"), "\n", [:append])

    {_, code} =
      command([
        "--action",
        "run",
        "--fixture",
        fixture,
        "--path",
        Path.join(root, "corrupt"),
        "--output",
        Path.join(root, "corrupt.json")
      ])

    assert code != 0
    refute File.exists?(Path.join(root, "corrupt"))
  end

  defp command(arguments) do
    System.cmd(
      System.find_executable("mix"),
      ["run", "--no-start", "--no-compile", Path.expand("bench/compaction.exs") | arguments],
      env: [{"ERL_FLAGS", "+S 2:2 +A 2"}, {"MIX_ENV", Atom.to_string(Mix.env())}],
      stderr_to_stdout: true
    )
  end

  defp contents(root) do
    Path.wildcard(Path.join(root, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path ->
      {Path.relative_to(path, root), :crypto.hash(:sha256, File.read!(path))}
    end)
  end
end
