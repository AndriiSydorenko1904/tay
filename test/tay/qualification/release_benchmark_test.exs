defmodule Tay.Qualification.ReleaseBenchmarkTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 60_000

  test "release benchmark excludes warmup and verifies every measured completion" do
    root = Tay.Test.NativeHelpers.path()
    output = root <> ".json"

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm(output)
    end)

    {text, status} =
      System.cmd(
        System.find_executable("mix"),
        [
          "run",
          "--no-start",
          "--no-compile",
          Path.expand("bench/release.exs"),
          "--path",
          root,
          "--output",
          output,
          "--jobs",
          "40",
          "--clients",
          "2",
          "--warmup-jobs",
          "10",
          "--trials",
          "1"
        ],
        env: [{"ERL_FLAGS", "+S 2:2 +A 2"}, {"MIX_ENV", Atom.to_string(Mix.env())}],
        stderr_to_stdout: true
      )

    assert status == 0, text
    report = output |> File.read!() |> JSON.decode!()
    assert report["benchmark"] == "tay-release-v2"
    assert %{"jobs" => 40, "warmup_jobs" => 10, "max_inflight" => 2} = report["workload"]
    assert [%{"jobs" => 40, "completed_jobs_per_second" => throughput}] = report["measurements"]
    assert throughput > 0
    assert File.dir?(Path.join(root, "warmup"))
    assert File.dir?(Path.join(root, "store-1"))
  end
end
