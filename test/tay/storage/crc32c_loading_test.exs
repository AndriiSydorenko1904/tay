defmodule Tay.Storage.CRC32CLoadingTest do
  use ExUnit.Case, async: true

  test "a detached VM without the native library fails instead of using the historical implementation" do
    root = Path.join(System.tmp_dir!(), "tay-crc-loading-#{System.unique_integer([:positive])}")
    ebin = Path.join([root, "tay-#{Application.spec(:tay, :vsn)}", "ebin"])
    File.mkdir_p!(ebin)
    on_exit(fn -> File.rm_rf!(root) end)

    for module <- [Tay.Storage.CRC32C, Tay.Storage.CRC32C.Native, Tay.Storage.CRC32C.Reference] do
      File.cp!(List.to_string(:code.which(module)), Path.join(ebin, "#{module}.beam"))
    end

    File.cp!(Application.app_dir(:tay, "ebin/tay.app"), Path.join(ebin, "tay.app"))

    code = """
    {:error, :on_load_failure} = Code.ensure_loaded(Tay.Storage.CRC32C.Native)
    0xE3069283 = Tay.Storage.CRC32C.Reference.checksum("123456789")

    try do
      Tay.Storage.CRC32C.checksum("123456789")
      raise "CRC32C unexpectedly succeeded without the NIF"
    rescue
      UndefinedFunctionError -> IO.puts("CRC32C_REQUIRES_NIF_OK")
    end
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", code],
        env: [{"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1 +A 1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "CRC32C_REQUIRES_NIF_OK"
  end
end
