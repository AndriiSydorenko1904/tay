defmodule Tay.System.PackageTest do
  use ExUnit.Case, async: false
  import Bitwise

  @moduletag :package
  @moduletag timeout: 240_000
  @moduletag skip: System.get_env("TAY_PACKAGE_TEST") != "1"
  @checkout Path.expand("../../..", __DIR__)

  test "offline source package builds a detached production consumer and compiler-free release" do
    base = System.get_env("TAY_TEST_DATA_ROOT") || System.tmp_dir!()
    {path, 0} = System.cmd("mktemp", ["-d", Path.join(base, "tay-package.XXXXXX")])
    artifact = String.trim(path)
    IO.puts("Package qualification artifacts: #{artifact}")
    consumer = Path.join(artifact, "consumer")
    vendor = Path.join(consumer, "vendor/tay")
    File.mkdir_p!(Path.dirname(vendor))
    build_env = build_env(artifact)

    command!("mix", ["hex.build", "--unpack", "--output", vendor], @checkout, build_env)

    assert File.read!(Path.join(vendor, "c_src/tay_storage_helper.c")) ==
             File.read!(Path.join(@checkout, "c_src/tay_storage_helper.c"))

    assert File.read!(Path.join(vendor, "scripts/tay_cold_copy.py")) ==
             File.read!(Path.join(@checkout, "scripts/tay_cold_copy.py"))

    assert File.regular?(Path.join(vendor, "c_src/README.md"))

    for forbidden <- ["test", "priv", "config", ".git", "_build", "deps"],
        do: refute(File.exists?(Path.join(vendor, forbidden)))

    templates = Path.join(@checkout, "test/support/package_consumer")

    for source <- Path.wildcard(Path.join(templates, "**/*.template")) do
      relative = source |> Path.relative_to(templates) |> String.replace_suffix(".template", "")
      target = Path.join(consumer, relative)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
    end

    assembled = Path.join(artifact, "assembled")
    command!("mix", ["compile", "--warnings-as-errors"], consumer, build_env)
    command!("mix", ["release", "tay_qualification", "--path", assembled], consumer, build_env)
    deployed = Path.join(artifact, "deployed")
    File.cp_r!(assembled, deployed)
    # Original absolute source/build/release paths no longer exist. The renamed
    # artifacts remain available for diagnosis if any assertion fails.
    File.rename!(consumer, Path.join(artifact, "unavailable-consumer"))
    File.rename!(assembled, Path.join(artifact, "unavailable-assembled"))
    File.rename!(Path.join(artifact, "build"), Path.join(artifact, "unavailable-build"))
    [helper] = Path.wildcard(Path.join(deployed, "lib/tay-*/priv/tay_storage_helper"))
    assert File.regular?(helper)
    assert (File.stat!(helper).mode &&& 0o111) != 0
    assert Path.wildcard(Path.join(deployed, "lib/tay-*/priv/*")) == [helper]
    assert Path.wildcard(Path.join(deployed, "lib/tay-*/scripts")) == []
    {architecture, 0} = System.cmd("file", [helper])
    assert architecture =~ "executable"
    IO.puts(String.trim(architecture))

    runtime_env = [
      {"PATH", runtime_path(artifact)},
      {"ERL_FLAGS", "+S 2:2 +A 2"},
      {"MIX_ENV", nil},
      {"MIX_BUILD_PATH", nil},
      {"TAY_PACKAGE_STORE", Path.join(artifact, "store")},
      {"TAY_PACKAGE_EFFECT", Path.join(artifact, "effects")}
    ]

    output =
      command!(
        Path.join(deployed, "bin/tay_qualification"),
        ["eval", "TayQualification.Probe.verify()"],
        deployed,
        runtime_env
      )

    assert output =~ "TAY_PACKAGE_RELEASE_OK"

    if System.get_env("TAY_TEST_SYNC") == "1" do
      assert output =~ "TAY_PACKAGE_SYNC_LIFECYCLE_OK"
    else
      refute File.exists?(Path.join(artifact, "store"))
    end

    # Only delete this exact newly created artifact root after complete success.
    # Failures intentionally retain all evidence at the path printed above.
    unless System.get_env("TAY_PACKAGE_KEEP") == "1", do: File.rm_rf!(artifact)
  end

  defp build_env(artifact) do
    [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", Path.join(artifact, "build")},
      {"HEX_HOME", Path.join(artifact, "hex")},
      {"HEX_OFFLINE", "1"},
      {"TAY_NATIVE_SANITIZE", nil},
      {"ERL_FLAGS", "+S 2:2 +A 2"},
      {"TAY_PACKAGE_STORE", Path.join(artifact, "store")}
    ]
  end

  defp runtime_path(artifact) do
    path = Path.join(artifact, "runtime-bin")
    File.mkdir!(path)

    # Release shell launchers may use basic OS utilities, but neither compiler,
    # Mix nor a system Erlang/Elixir executable is admitted to the runtime PATH.
    for name <-
          ~w(basename dirname readlink sed cut cat ls awk tr expr getconf uname mkdir realpath grep) do
      if executable = System.find_executable(name),
        do: File.ln_s!(executable, Path.join(path, name))
    end

    path
  end

  defp command!(executable, args, directory, env) do
    IO.puts("#{directory}: #{executable} #{Enum.join(args, " ")}")
    {output, code} = System.cmd(executable, args, cd: directory, env: env, stderr_to_stdout: true)
    IO.puts(output)
    assert code == 0, "command failed (#{code}); artifacts preserved\n#{output}"
    output
  end
end
