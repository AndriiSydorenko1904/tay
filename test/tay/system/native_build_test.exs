defmodule Tay.System.NativeBuildTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 60_000

  test "native builds cache inputs, rebuild missing outputs and isolate test artifacts" do
    root = Path.join(System.tmp_dir!(), "tay-native-build-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "mix_helpers"))
    File.mkdir_p!(Path.join(root, "c_src"))
    on_exit(fn -> File.rm_rf!(root) end)

    for file <- ["mix_helpers/tay_native.exs", "c_src/tay_storage_helper.c", "c_src/tay_crc32c.c"],
        do: File.cp!(file, Path.join(root, file))

    File.write!(Path.join(root, "mix.exs"), """
    Code.require_file("mix_helpers/tay_native.exs", __DIR__)
    defmodule TayNativeFixture.MixProject do
      use Mix.Project
      def project, do: [app: :tay, version: "0.0.0", deps: []]
    end
    """)

    env = [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", Path.join(root, "build")},
      {"ERL_FLAGS", "+S 2:2 +A 2"},
      {"TAY_NATIVE_SANITIZE", "0"}
    ]

    # Environment keys are strings; merge without converting them to atoms.
    build = fn extra_env, args ->
      merged = Map.to_list(Map.merge(Map.new(env), Map.new(extra_env)))

      {output, code} =
        System.cmd(System.find_executable("mix"), ["compile.tay_native" | args],
          cd: root,
          env: merged,
          stderr_to_stdout: true
        )

      assert code == 0, output
    end

    artifact = fn name -> Path.join([root, "build", "lib", "tay", "priv", name]) end
    build.([], [])
    helper = File.stat!(artifact.("tay_storage_helper")).inode
    crc = File.stat!(artifact.("tay_crc32c.so")).inode
    assert File.regular?(artifact.("tay_storage_helper_test"))
    build.([], [])
    assert File.stat!(artifact.("tay_storage_helper")).inode == helper
    assert File.stat!(artifact.("tay_crc32c.so")).inode == crc

    File.write!(Path.join(root, "c_src/tay_storage_helper.c"), "\n/* input changed */\n", [
      :append
    ])

    build.([], [])
    refute File.stat!(artifact.("tay_storage_helper")).inode == helper
    assert File.stat!(artifact.("tay_crc32c.so")).inode == crc
    File.rm!(artifact.("tay_crc32c.so"))
    build.([], [])
    assert File.regular?(artifact.("tay_crc32c.so"))
    build.([{"MIX_ENV", "prod"}], [])
    refute File.exists?(artifact.("tay_storage_helper_test"))
    helper = File.stat!(artifact.("tay_storage_helper")).inode
    build.([{"MIX_ENV", "prod"}], ["--force"])
    refute File.stat!(artifact.("tay_storage_helper")).inode == helper
  end
end
